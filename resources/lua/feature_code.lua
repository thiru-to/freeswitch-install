--[[
  Feature codes a user dials from their own handset to change their call handling.

    *78          do not disturb on
    *79          do not disturb off
    *72<number>  forward all calls to <number>
    *73          cancel forward all
    *90<number>  forward to <number> when busy
    *91          cancel busy forward
    *92<number>  forward to <number> when there is no answer
    *93          cancel no-answer forward

  The change is written through the API rather than straight to Redis. Redis is a cache: a
  write there would be correct until the next rebuild silently reverted it, and the user would
  have no idea their phone had stopped forwarding. The API owns Postgres and repopulates the
  cache, so this is the only path that makes the change stick.

  Usage:  <action application="lua" data="feature_code.lua <domain> <user> <action> [value]"/>
--]]

local voip = require "voip"

local domain, user, what, value = argv[1], argv[2], argv[3], argv[4]

if not session or not session:ready() then return end
if not domain or not user or not what then
  voip.log("feature", "err", "usage: feature_code.lua <domain> <user> <action> [value]")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

session:answer()
session:execute("playback", "silence_stream://300")

--[[ A forward target is dialled digits, so it is whatever the user's fingers produced. It ends
     up in a JSON body and then in a bridge string, so anything that is not a diallable
     character is rejected rather than escaped - there is no legitimate forward target
     containing a quote. ]]
if value and value ~= "" and not value:match("^[0-9*#+]+$") then
  voip.log("feature", "warning", "%s@%s: refusing forward target %q", user, domain, value)
  session:streamFile("ivr/ivr-that_was_an_invalid_entry.wav")
  session:hangup("NORMAL_CLEARING")
  return
end

local FIELDS = {
  dnd_on          = { field = "dnd", value = "true" },
  dnd_off         = { field = "dnd", value = "false" },
  fwd_all_set     = { field = "forwardAllTo", value = value },
  fwd_all_clear   = { field = "forwardAllTo", value = nil },
  fwd_busy_set    = { field = "forwardBusyTo", value = value },
  fwd_busy_clear  = { field = "forwardBusyTo", value = nil },
  fwd_na_set      = { field = "forwardNoAnswerTo", value = value },
  fwd_na_clear    = { field = "forwardNoAnswerTo", value = nil },
}

local change = FIELDS[what]
if not change then
  voip.log("feature", "err", "unknown feature action %q", tostring(what))
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

-- Setting a forward with no digits is a mis-dial, not a request to clear it: *72 on its own
-- should complain rather than silently cancelling a forward the user meant to keep.
if what:match("_set$") and (not value or value == "") then
  session:streamFile("ivr/ivr-that_was_an_invalid_entry.wav")
  session:hangup("NORMAL_CLEARING")
  return
end

local encoded
if change.value == nil then
  encoded = "null"
elseif change.value == "true" or change.value == "false" then
  encoded = change.value
else
  encoded = '"' .. change.value .. '"'
end

local api = os.getenv("VOIP_API_BASE") or "http://127.0.0.1:3000"
local secret = os.getenv("VOIP_FS_GATEWAY_SECRET") or ""
local payload = string.format('{"domain":"%s","number":"%s","%s":%s}',
  domain, user, change.field, encoded)

local cmd = string.format(
  "%s/fs/feature -m 5 -X POST -H 'Content-Type: application/json' -u 'fs:%s' -d '%s'",
  api, secret, payload)

local ok, reply = pcall(function() return freeswitch.API():execute("curl", cmd) end)
local applied = ok and reply and reply:find('"ok"%s*:%s*true') ~= nil

if applied then
  voip.log("feature", "info", "%s@%s: %s -> %s", user, domain, change.field, tostring(change.value))
  -- Confirmation tone rather than a spoken prompt: the vanilla sound set has no phrase for
  -- most of these, and a wrong prompt is worse than a tone the user learns.
  session:streamFile("tone_stream://%(200,100,600);%(200,100,800)")
else
  --[[ Say so. A feature code that appears to work but did not is the kind of failure a user
       only discovers when they miss a call. ]]
  voip.log("feature", "err", "%s@%s: %s NOT applied (%s)",
    user, domain, change.field, tostring(reply))
  session:streamFile("ivr/ivr-call_cannot_be_completed_at_this_time.wav")
end

session:hangup("NORMAL_CLEARING")
