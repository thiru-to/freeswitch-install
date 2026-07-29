--[[
  IVR: plays a greeting, collects one digit, routes.

  Usage:  <action application="lua" data="ivr.lua <domain> <id> [depth]"/>
--]]

local voip = require "voip"

local domain, id, depth = argv[1], argv[2], tonumber(argv[3] or "0")

if not session or not session:ready() then return end
if not domain or not id then
  voip.log("ivr", "err", "usage: ivr.lua <domain> <id>")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

local menu = voip.fetch("ivr", domain, id)
if not menu then
  voip.log("ivr", "err", "no IVR menu %s@%s in cache", id, domain)
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

session:answer()
-- Callers dial over the greeting constantly. Without a moment of silence first, the first
-- digit lands before the media path is fully up and is simply lost.
session:execute("playback", "silence_stream://500")

local greeting = menu.greetingSound or "silence_stream://1000"
local invalid = menu.invalidSound or "silence_stream://500"
local timeout_ms = (menu.timeoutSec or 5) * 1000
local max_retries = menu.maxRetries or 3

local options = menu.options or {}

for attempt = 1, max_retries do
  if not session:ready() then return end

  --[[ playAndGetDigits(min, max, tries, timeout, terminators, file, invalid_file, regex)

       tries is 1 here and the retry loop is ours, so that an invalid entry and a timeout can
       be logged differently - "nobody pressed anything" and "they pressed 9 and there is no 9"
       are different customer problems, and FreeSWITCH's own retry collapses them. ]]
  local digit = session:playAndGetDigits(1, 1, 1, timeout_ms, "#", greeting, invalid, "\\d|\\*|#")

  if digit and digit ~= "" then
    local choice = options[digit]
    if choice then
      voip.log("ivr", "info", "%s: caller pressed %s -> %s", menu.name, digit, tostring(choice.type))
      voip.go(session, domain, choice.type, choice.id, depth)
      return
    end
    voip.log("ivr", "info", "%s: invalid digit %s (attempt %d/%d)",
      menu.name, digit, attempt, max_retries)
    session:execute("playback", invalid)
  else
    voip.log("ivr", "info", "%s: no digit (attempt %d/%d)", menu.name, attempt, max_retries)
  end
end

--[[ Out of retries. This is the most common real-world path - rotary phones, callers who put
     the handset down, speech that never registers - so it has to lead somewhere sensible
     rather than a hangup. ]]
voip.log("ivr", "info", "%s: exhausted %d attempts -> %s",
  menu.name, max_retries, tostring(menu.timeoutType))

if menu.timeoutType then
  voip.go(session, domain, menu.timeoutType, menu.timeoutId, depth)
else
  session:hangup("NO_ROUTE_DESTINATION")
end
