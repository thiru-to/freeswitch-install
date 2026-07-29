--[[
  Time condition: routes a call by whether "now" falls inside the configured windows.

  Evaluated in the TENANT's timezone, not the server's. A customer in Toronto and one in
  Vancouver have different business hours, and using the server clock would silently give one
  of them the wrong answer for half the year - which is worse than an error, because after-hours
  calls just quietly go to the wrong place.

  Usage:  <action application="lua" data="time_condition.lua <domain> <id> [depth]"/>
--]]

local voip = require "voip"

local domain, id, depth = argv[1], argv[2], tonumber(argv[3] or "0")

if not session or not session:ready() then return end
if not domain or not id then
  voip.log("time_condition", "err", "usage: time_condition.lua <domain> <id>")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

local cond = voip.fetch("tc", domain, id)
if not cond then
  -- The cache is authoritative here; falling back to Postgres mid-call would mean a database
  -- round trip the caller waits through. Failing to the no-match branch is not safe either -
  -- we do not know what it is - so this is one of the few places that hangs up.
  voip.log("time_condition", "err", "no time condition %s@%s in cache", id, domain)
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

--[[ Local time in the tenant's zone.

     Lua's os.date only knows the process TZ, so this goes through FreeSWITCH's `strftime_tz`
     API (mod_commands), which resolves the zone name against timezones.conf.xml and handles
     DST from the embedded rule - no libc TZ fiddling, and no shelling out per call.

     The separator is a comma, deliberately: strftime_tz parses `<tz> [<epoch>|]<format>` and
     treats a `|` in the format as an epoch delimiter, which would silently mangle the output. ]]
local function now_in(tz)
  local zone = (tz and tz ~= "") and tz or "Etc/UTC"
  local stamp = freeswitch.API():execute("strftime_tz", zone .. " %w,%H:%M,%Y-%m-%d")
  if stamp then
    local wday, hhmm, date = stamp:match("^(%d),(%d%d:%d%d),(%d%d%d%d%-%d%d%-%d%d)")
    if wday then
      return tonumber(wday), hhmm, date
    end
  end
  --[[ Unknown zone name, or the API is missing. Fall back to the server clock rather than
       failing the call, but say so loudly - after-hours routing that is quietly an hour out is
       the kind of bug that gets noticed by a customer's customer, not by us. ]]
  voip.log("time_condition", "warning",
    "timezone '%s' did not resolve (%s) - falling back to the server clock",
    zone, tostring(stamp))
  local t = os.date("*t")
  return t.wday - 1, string.format("%02d:%02d", t.hour, t.min), os.date("%Y-%m-%d")
end

local wday, hhmm, today = now_in(cond.timezone)

--[[ A rule matches when every field it specifies matches. Absent fields are wildcards, so
     `{days=[1..5]}` is all day Monday to Friday and `{date=...}` is that date whatever the
     weekday - which is how holidays are expressed. ]]
local function rule_matches(rule)
  if rule.date and rule.date ~= today then return false end
  if rule.days then
    local ok = false
    for _, d in ipairs(rule.days) do
      if tonumber(d) == wday then ok = true break end
    end
    if not ok then return false end
  end
  if rule.start and hhmm < rule.start then return false end
  if rule["end"] and hhmm >= rule["end"] then return false end
  return true
end

--[[ `invert` turns a rule into an exclusion - how a holiday carves a hole in an otherwise
     matching weekday window. An exclusion that matches is therefore FINAL: it has to beat the
     "Mon-Fri 09:00-17:00" rule that will also match, or Christmas Day routes to the sales
     team. Ordering in the list does not matter; the exclusion wins wherever it sits. ]]
local matched = false
for _, rule in ipairs(cond.rules or {}) do
  if rule_matches(rule) then
    if rule.invert then
      matched = false
      break
    end
    matched = true
  end
end

voip.log("time_condition", "info", "%s: %s (%s %s in %s) -> %s branch",
  cond.name, matched and "MATCH" or "no match", today, hhmm, cond.timezone,
  matched and tostring(cond.matchType) or tostring(cond.noMatchType))

local dtype = matched and cond.matchType or cond.noMatchType
local did = matched and cond.matchId or cond.noMatchId

if not dtype then
  voip.log("time_condition", "warning", "%s has no %s destination configured",
    cond.name, matched and "match" or "no-match")
  session:hangup("UNALLOCATED_NUMBER")
  return
end

voip.go(session, domain, dtype, did, depth)
