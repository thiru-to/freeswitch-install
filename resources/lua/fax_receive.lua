--[[
  Inbound fax receive.

  Invoked from the dialplan when an inbound DID has destinationType = "fax" (see
  xml_handler.lua). Answers, negotiates T.38 where the far end supports it, receives to TIFF,
  and reports the outcome to the API which converts to PDF and delivers.

  Fax over IP is fragile by nature and this is the hard topology for it: a B2BUA plus two
  rtpengine relays. Everything here is therefore written to record WHY a transfer failed
  rather than just that it did - spandsp's result codes are the only diagnostic you get, and
  losing them means every failure looks identical.

  Usage from the dialplan:  <action application="lua" data="fax_receive.lua <domain> <did>"/>
--]]

local domain = argv[1]
local did = argv[2]

local function log(level, fmt, ...)
  freeswitch.consoleLog(level, "[fax_receive] " .. string.format(fmt, ...) .. "\n")
end

if not session or not session:ready() then
  log("err", "no session")
  return
end

if not domain or not did then
  log("err", "usage: fax_receive.lua <domain> <did>")
  session:hangup("NORMAL_TEMPORARY_FAILURE")
  return
end

local uuid = session:getVariable("uuid")
local caller = session:getVariable("caller_id_number") or "unknown"
local caller_name = session:getVariable("caller_id_name") or ""

--[[ Storage. One directory per day keeps a busy tenant's fax spool navigable, and the
     filename carries the UUID so a TIFF can always be traced back to its channel. ]]
local spool = os.getenv("VOIP_FAX_SPOOL") or "/var/spool/voip-fax"
local day = os.date("%Y-%m-%d")
local dir = string.format("%s/%s/%s", spool, domain, day)
-- 2770 with the group inherited: the API (a different user) writes the converted PDF into
-- this directory, so a default-umask 0755 root-owned directory would break conversion in a
-- way that only shows up as a missing PDF, never as an error on this side.
os.execute(string.format("mkdir -p '%s' && chmod -R 2770 '%s' 2>/dev/null", dir, spool))
local tiff = string.format("%s/%s.tif", dir, uuid)

log("notice", "inbound fax on %s@%s from %s -> %s", did, domain, caller, tiff)

--[[ T.38 negotiation.

     enable_t38_request lets the far end switch us into T.38 mid-call, which is how most
     carriers do it - they detect the CNG tone and re-INVITE. Passthrough is left enabled as
     the fallback for endpoints that will not negotiate T.38 at all, where spandsp decodes
     the audio directly. Without both, a meaningful share of real-world senders fail. ]]
session:execute("set", "fax_enable_t38=true")
session:execute("set", "fax_enable_t38_request=true")
session:execute("set", "t38_passthru=false")
-- Identify ourselves to the sender; some machines log or display this.
session:execute("set", "fax_ident=" .. did)
session:execute("set", "fax_header=" .. domain)

session:answer()
-- A short pause before rxfax: answering and immediately starting the negotiation loses the
-- first tones on some carriers.
session:execute("playback", "silence_stream://2000")

session:execute("rxfax", tiff)

--[[ Result. spandsp sets these after rxfax returns; they are the only diagnostic available,
     so all of them are captured rather than just success/failure. ]]
local success = session:getVariable("fax_success")
local result_code = session:getVariable("fax_result_code")
local result_text = session:getVariable("fax_result_text")
local pages = session:getVariable("fax_document_transferred_pages") or "0"
local remote_id = session:getVariable("fax_remote_station_id") or ""

local ok = (success == "1")
log(ok and "notice" or "warning",
  "fax %s: pages=%s code=%s text=%s remote=%s",
  ok and "received" or "FAILED", pages, tostring(result_code), tostring(result_text), remote_id)

--[[ Report to the API, which converts to PDF and delivers.

     Deliberately fire-and-forget with a short timeout: the caller has already hung up by the
     time this runs, and the TIFF is safely on disk either way. An API outage must not turn a
     received fax into a lost one - the file is on disk and reconcilable. ]]
local api = os.getenv("VOIP_API_BASE") or "http://127.0.0.1:3000"
local secret = os.getenv("VOIP_FS_GATEWAY_SECRET") or ""

local payload = string.format(
  '{"callUuid":"%s","domain":"%s","did":"%s","callerNumber":"%s","callerName":"%s",' ..
  '"filePath":"%s","pages":%s,"status":"%s","failureReason":"%s","remoteStationId":"%s"}',
  uuid, domain, did, caller, caller_name:gsub('"', ""), tiff,
  tonumber(pages) or 0, ok and "received" or "failed",
  tostring(result_text):gsub('"', ""), remote_id:gsub('"', ""))

local curl = freeswitch.API()
local cmd = string.format(
  "%s/fs/fax -m 5 -X POST -H 'Content-Type: application/json' -u 'fs:%s' -d '%s'",
  api, secret, payload:gsub("'", ""))

local sent, err = pcall(function() return curl:execute("curl", cmd) end)
if not sent then
  log("err", "could not report fax to the API (%s) - TIFF is on disk at %s", tostring(err), tiff)
end

session:hangup("NORMAL_CLEARING")
