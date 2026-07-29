--[[
  Terminating a call to one extension.

  This is where a user's own call handling applies - do not disturb, the three kinds of
  forwarding, call waiting, and finally voicemail. It is a script rather than dialplan XML
  because the decision after the bridge depends on WHY the bridge failed: busy and no-answer
  are different outcomes with different forward targets, and static XML cannot branch on that.

  Usage:  <action application="lua" data="extension.lua <domain> <number> [depth]"/>
--]]

local voip = require "voip"

local domain, number, depth = argv[1], argv[2], tonumber(argv[3] or "0")

if not session or not session:ready() then return end
if not domain or not number then
  voip.log("extension", "err", "usage: extension.lua <domain> <number>")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

--[[ Absent settings are not an error. An extension that exists in the directory but has no
     call-handling entry - a cache still warming, say - should ring normally rather than fail;
     the defaults below are exactly "ring the phone, then voicemail". ]]
local ext = voip.fetch("call", domain, number) or {}
local ring_timeout = ext.ringTimeoutSec or 25

--[[ Unconditional forward wins over everything, including DND: a user who has forwarded their
     phone to their mobile has said where calls go, and quietly sending them to voicemail
     instead because DND is also set would lose the call. ]]
if ext.forwardAllTo and ext.forwardAllTo ~= "" then
  voip.log("extension", "info", "%s@%s: forwarded to %s", number, domain, ext.forwardAllTo)
  session:execute("set", "sip_h_X-Forwarded-From=" .. number)
  voip.go(session, domain, "external", ext.forwardAllTo, depth)
  return
end

--[[ Shared by the DND, busy and no-answer paths. Each has its own forward target, and each
     falls back to voicemail when none is set. ]]
local function no_answer_treatment(reason, forward_to)
  if not session:ready() then return end

  if forward_to and forward_to ~= "" then
    voip.log("extension", "info", "%s@%s: %s, forwarding to %s", number, domain, reason, forward_to)
    session:execute("set", "sip_h_X-Forwarded-From=" .. number)
    voip.go(session, domain, "external", forward_to, depth)
    return
  end

  if ext.voicemailEnabled == false then
    voip.log("extension", "info", "%s@%s: %s, no voicemail - hanging up", number, domain, reason)
    session:hangup(reason == "busy" and "USER_BUSY" or "NO_ANSWER")
    return
  end

  voip.log("extension", "info", "%s@%s: %s, taking a message", number, domain, reason)
  session:execute("answer", "")
  session:execute("voicemail", string.format("default %s %s", domain, number))
end

if ext.dnd then
  --[[ Do not ring at all. The caller still gets the full treatment - a DND user's callers
       should reach voicemail, not a dead line. ]]
  voip.log("extension", "info", "%s@%s: DND", number, domain)
  no_answer_treatment("dnd", ext.forwardNoAnswerTo)
  return
end

--[[ Call waiting off means a second simultaneous call is busy rather than a second ring.

     Handled here rather than left to the handset, because the handset can only reject the call
     - it cannot send it to this user's busy-forward number or their mailbox.

     The count is READ with limit_usage and judged here, instead of letting the `limit`
     application enforce the maximum. `limit ... !USER_BUSY` hangs the channel up outright
     (mod_dptools.c: switch_channel_hangup on exceed), which would skip the busy treatment
     below - the caller would get a busy tone and the user's busy-forward would never fire,
     which is the exact failure this block exists to prevent.

     The read and the increment are not atomic. For "is this one person already on a call" that
     is fine; two calls landing in the same millisecond is not a case worth a lock.

     The `hash` backend is per-node. With several media nodes this needs the hiredis limit
     backend instead, which is why the backend is named here rather than left to default. ]]
local LIMIT_BACKEND = "hash"

if ext.callWaitingEnabled == false then
  local usage = tonumber(
    freeswitch.API():execute("limit_usage",
      string.format("%s %s %s", LIMIT_BACKEND, domain, number)) or "0") or 0
  if usage >= 1 then
    voip.log("extension", "info", "%s@%s: on a call and call waiting is off", number, domain)
    no_answer_treatment("busy", ext.forwardBusyTo)
    return
  end
end

-- Counter only - no maximum, so this never hangs the call up. It exists so the check above can
-- see this call, and it is released automatically when the channel ends.
session:execute("limit", string.format("%s %s %s", LIMIT_BACKEND, domain, number))

session:execute("set", "call_timeout=" .. tostring(ring_timeout))
session:execute("set", "hangup_after_bridge=true")
-- Without this a busy or unregistered endpoint hangs up the caller and none of the treatment
-- below runs.
session:execute("set", "continue_on_fail=true")
session:execute("set", "ignore_early_media=false")

session:execute("bridge", string.format("user/%s@%s", number, domain))

-- Reached only when the bridge failed; an answered call is torn down by hangup_after_bridge.
if not session:ready() then return end

--[[ Busy and no-answer are different outcomes with different forward targets, so the
     disposition has to be inspected rather than assumed. USER_BUSY covers both a phone
     rejecting the call and the call-waiting limit above. ]]
local cause = session:getVariable("originate_disposition") or "NO_ANSWER"
if cause == "USER_BUSY" or cause == "CALL_REJECTED" then
  no_answer_treatment("busy", ext.forwardBusyTo)
else
  no_answer_treatment("no answer", ext.forwardNoAnswerTo)
end
