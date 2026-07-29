--[[
  Shared helpers for the call-time scripts.

  Loaded with `require "voip"` - lua.conf.xml sets script-directory so this resolves.

  Destinations are polymorphic: an inbound route, an IVR option, a ring-group failover and
  both branches of a time condition all point at "an extension, or a ring group, or an IVR,
  or...". Dispatching that in one place means a new destination type is added once rather
  than in four scripts that then drift apart.
--]]

local M = {}

M.REDIS_PROFILE = "default"

function M.log(tag, level, fmt, ...)
  freeswitch.consoleLog(level, "[" .. tag .. "] " .. string.format(fmt, ...) .. "\n")
end

--[[ Redis via mod_hiredis. Synchronous, with a 200ms profile timeout - this runs mid-call, so
     a stall here is dead air the caller hears. ]]
function M.redis_get(key)
  local ok, result = pcall(function()
    return freeswitch.API():execute("hiredis_raw", M.REDIS_PROFILE .. " GET " .. key)
  end)
  if not ok or not result or result == "" or result:sub(1, 4) == "-ERR" then
    return nil
  end
  return result
end

function M.json_decode(str)
  if not str then return nil end
  local ok, obj = pcall(function() return freeswitch.JSON():decode(str) end)
  if ok then return obj end
  return nil
end

function M.fetch(kind, domain, id)
  return M.json_decode(M.redis_get(string.format("voip:%s:%s:%s", kind, domain, id)))
end

--[[ ---------------------------------------------------------------------------------------
  Destination dispatch.

  `depth` guards against a loop: an IVR option pointing at a time condition whose no-match
  points back at the IVR is a configuration a customer can build by accident, and without a
  ceiling it recurses until FreeSWITCH runs out of stack mid-call.
------------------------------------------------------------------------------------------ ]]

local MAX_DEPTH = 10

function M.go(session, domain, dtype, did, depth)
  depth = (depth or 0) + 1
  if depth > MAX_DEPTH then
    M.log("voip", "err", "destination chain exceeded %d hops at %s/%s - hanging up",
      MAX_DEPTH, tostring(dtype), tostring(did))
    session:hangup("EXCHANGE_ROUTING_ERROR")
    return
  end

  if not session:ready() then
    M.log("voip", "info", "caller hung up before reaching %s", tostring(dtype))
    return
  end

  if dtype == "extension" then
    -- did is the extension row id for stored destinations, but the number for a direct dial.
    -- Both are supported: the caller passes whichever it holds.
    local number = did
    session:execute("set", "hangup_after_bridge=true")
    session:execute("bridge", string.format("user/%s@%s", number, domain))
    -- Only reached if the bridge failed; an answered call never returns here.
    if session:ready() then
      session:execute("answer", "")
      session:execute("voicemail", string.format("default %s %s", domain, number))
    end

  elseif dtype == "ring_group" then
    session:execute("lua", string.format("ring_group.lua %s %s %d", domain, did, depth))

  elseif dtype == "ivr" then
    session:execute("lua", string.format("ivr.lua %s %s %d", domain, did, depth))

  elseif dtype == "time_condition" then
    session:execute("lua", string.format("time_condition.lua %s %s %d", domain, did, depth))

  elseif dtype == "voicemail" then
    session:execute("answer", "")
    session:execute("voicemail", string.format("default %s %s", domain, tostring(did)))

  elseif dtype == "fax" then
    session:execute("answer", "")
    session:execute("playback", "silence_stream://2000")
    session:execute("lua", string.format("fax_receive.lua %s %s", domain, tostring(did)))

  elseif dtype == "external" then
    -- A literal number, routed like any outbound call - back out through Kamailio's egress.
    local egress = os.getenv("VOIP_KAM_EGRESS") or "127.0.0.1:5070"
    session:execute("set", "hangup_after_bridge=true")
    session:execute("bridge", string.format("sofia/external/%s@%s", tostring(did), egress))

  elseif dtype == "hangup" then
    session:hangup("NORMAL_CLEARING")

  else
    M.log("voip", "warning", "unknown destination type '%s' - hanging up", tostring(dtype))
    session:hangup("UNALLOCATED_NUMBER")
  end
end

return M
