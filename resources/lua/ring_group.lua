--[[
  Ring group: rings several extensions, then falls over.

  Usage:  <action application="lua" data="ring_group.lua <domain> <id> [depth]"/>
--]]

local voip = require "voip"

local domain, id, depth = argv[1], argv[2], tonumber(argv[3] or "0")

if not session or not session:ready() then return end
if not domain or not id then
  voip.log("ring_group", "err", "usage: ring_group.lua <domain> <id>")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

local group = voip.fetch("rg", domain, id)
if not group then
  voip.log("ring_group", "err", "no ring group %s@%s in cache", id, domain)
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

local members = group.members or {}
if #members == 0 then
  -- An empty group is a configuration mistake, but hanging up on the caller is the wrong
  -- response to it: go straight to failover if there is one.
  voip.log("ring_group", "warning", "ring group %s has no enabled members", group.name)
  if group.failoverType then
    voip.go(session, domain, group.failoverType, group.failoverId, depth)
  else
    session:hangup("NO_ROUTE_DESTINATION")
  end
  return
end

--[[ Build the bridge string.

     FreeSWITCH expresses ring strategies in the dial string itself rather than by looping:
       ","  simultaneous - ring everyone at once
       "|"  sequential   - try each in turn
     Doing it in one bridge rather than a Lua loop matters, because a loop would answer the
     inbound leg to keep it alive between attempts, and an answered call is a billed call. ]]
local separator = (group.strategy == "sequential") and "|" or ","

local dials = {}
for _, m in ipairs(members) do
  local leg = string.format("user/%s@%s", m.number, domain)
  -- A per-member delay lets a manager's phone start ringing after the team's. Expressed as a
  -- leg variable so it works within the single bridge above.
  if m.delaySec and m.delaySec > 0 and separator == "," then
    leg = string.format("[leg_delay_start=%d]%s", m.delaySec, leg)
  end
  table.insert(dials, leg)
end

local dial_string = table.concat(dials, separator)

voip.log("ring_group", "info", "%s: ringing %d member(s) %s for %ds",
  group.name, #members, (separator == "|") and "sequentially" or "simultaneously",
  group.ringTimeoutSec or 30)

session:execute("set", "call_timeout=" .. tostring(group.ringTimeoutSec or 30))
session:execute("set", "hangup_after_bridge=true")
-- Without this a failed bridge hangs up the caller and the failover below never runs.
session:execute("set", "continue_on_fail=true")
session:execute("set", "ignore_early_media=true")

session:execute("bridge", dial_string)

--[[ Reached only if nobody answered - an answered call is torn down by hangup_after_bridge. ]]
if not session:ready() then return end

local cause = session:getVariable("originate_disposition") or "NO_ANSWER"
voip.log("ring_group", "info", "%s: nobody answered (%s)", group.name, cause)

if group.failoverType then
  voip.go(session, domain, group.failoverType, group.failoverId, depth)
else
  session:execute("answer", "")
  session:execute("voicemail", string.format("default %s %s", domain, group.number))
end
