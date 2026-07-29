--[[
  FreeSWITCH XML handler — the hot path.

  Bound via lua.conf.xml (xml-handler-script + xml-handler-bindings), which registers through
  switch_xml_bind_search_function — the same mechanism mod_xml_curl uses. This runs IN PROCESS,
  so a dialplan lookup costs a Redis round trip rather than an HTTP one, and the portal API can
  be down or mid-deploy without calls stopping.

  Fall-through chain, in order:
      Redis (this script)  ->  Postgres (this script, narrow)  ->  mod_xml_curl  ->  static
  Returning nothing here makes FreeSWITCH try the next binding, so declining is safe.

  The API is the only writer of the Redis keys read here. This script deliberately contains
  almost no SQL: every query in Lua is business logic living in a second language, so the
  Postgres fallback covers cold-cache safety only, not the full routing engine.

  Globals provided by mod_lua: `XML_REQUEST` (section, tag_name, key_name, key_value),
  `params` (an Event), and `XML_STRING` for the reply.
--]]

local M = {}

--[[ ---------------------------------------------------------------------------------------
  Configuration. Written by steps/31-freeswitch-config.sh.
--------------------------------------------------------------------------------------- ]]

local REDIS_PROFILE = "default"
local PG_DSN = os.getenv("VOIP_PG_DSN") or ""
local DEBUG = false

local function log(level, fmt, ...)
  freeswitch.consoleLog(level, "[xml_handler] " .. string.format(fmt, ...) .. "\n")
end

local function debug(fmt, ...)
  if DEBUG then log("debug", fmt, ...) end
end

--[[ ---------------------------------------------------------------------------------------
  Redis. mod_hiredis exposes `hiredis_raw <profile> <command>`; the profile carries the
  connection, password and a 200ms timeout (hiredis.conf.xml).

  hiredis_profile_execute_sync is synchronous, so this blocks call setup. The tight timeout is
  what keeps a Redis stall from becoming a stuck call.
--------------------------------------------------------------------------------------- ]]

local api = freeswitch.API()

local function redis_get(key)
  local ok, result = pcall(function()
    return api:execute("hiredis_raw", REDIS_PROFILE .. " GET " .. key)
  end)
  if not ok or not result then
    log("warning", "redis GET %s failed", key)
    return nil
  end
  -- mod_hiredis returns "-ERR ..." on a command error and an empty string for a missing key.
  if result == "" or result:sub(1, 4) == "-ERR" then
    return nil
  end
  return result
end

--[[ ---------------------------------------------------------------------------------------
  Postgres fallback. Narrow on purpose - two lookups, no routing logic.

  Requires mod_pgsql to be loaded: the core has no built-in pgsql:// DSN, only sqlite:// and
  odbc:// plus a pluggable database-interface path that mod_pgsql registers.
--------------------------------------------------------------------------------------- ]]

local function pg_query_one(sql)
  if PG_DSN == "" then return nil end
  local dbh = freeswitch.Dbh(PG_DSN)
  if not dbh or not dbh:connected() then
    log("warning", "postgres fallback unavailable (is mod_pgsql loaded?)")
    return nil
  end
  local row = nil
  dbh:query(sql, function(r) row = r end)
  dbh:release()
  return row
end

local function sql_escape(s)
  return (tostring(s or ""):gsub("'", "''"))
end

--[[ ---------------------------------------------------------------------------------------
  XML helpers
--------------------------------------------------------------------------------------- ]]

local NOT_FOUND = [[<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="result">
    <result status="not found"/>
  </section>
</document>]]

local function xml_escape(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  s = s:gsub('"', "&quot;"):gsub("'", "&apos;")
  return s
end

local function document(section, inner)
  return string.format(
    [[<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="%s">
%s
  </section>
</document>]],
    section,
    inner
  )
end

--[[ ---------------------------------------------------------------------------------------
  JSON. FreeSWITCH exposes a JSON parser, so no pure-Lua decoder is needed.
--------------------------------------------------------------------------------------- ]]

local function json_decode(str)
  if not str then return nil end
  local ok, obj = pcall(function()
    return freeswitch.JSON():decode(str)
  end)
  if ok then return obj end
  return nil
end

--[[ ---------------------------------------------------------------------------------------
  directory — user auth and registration.

  Bounded key space, so the rendered answer is cached whole. FreeSWITCH also caches this
  itself via the `cacheable` attribute the API embeds, giving a second layer above Redis; the
  portal calls xml_flush_cache on write so a long TTL does not delay changes.
--------------------------------------------------------------------------------------- ]]

function M.directory(req, p)
  local domain = p:getHeader("domain") or p:getHeader("sip_auth_realm") or req.key_value
  local user = p:getHeader("user") or p:getHeader("sip_auth_username")

  if not domain or not user then
    -- A directory fetch with no user is FreeSWITCH enumerating the domain (for example at
    -- startup). We serve per-user only; declining lets a static fallback answer.
    debug("directory request without user/domain - declining")
    return nil
  end

  local cached = redis_get("voip:dir:" .. domain .. ":" .. user)
  if cached then
    debug("directory hit %s@%s", user, domain)
    return document(
      "directory",
      string.format(
        [[    <domain name="%s">
      <params>
        <param name="dial-string" value="{^^:sip_invite_domain=${dialed_domain}:presence_id=${dialed_user}@${dialed_domain}}${sofia_contact(${dialed_user}@${dialed_domain})}"/>
      </params>
%s
    </domain>]],
        xml_escape(domain),
        cached
      )
    )
  end

  log("warning", "directory MISS %s@%s - falling through", user, domain)
  return nil
end

--[[ ---------------------------------------------------------------------------------------
  dialplan — every call setup.

  Not cached per dialled number: outbound destinations are an unbounded key space, so caching
  the answer would fill Redis with single-use keys and still miss on nearly every call.
  Instead the tenant's route TABLE is cached and matched here, giving a hit rate independent
  of what was dialled.

  Order matters and is not arbitrary:
    1. emergency  - matched first so it can never be blocked by a limit or time condition
    2. internal extension
    3. inbound DID
    4. outbound pattern match
--------------------------------------------------------------------------------------- ]]

local function action(app, data)
  return string.format(
    '          <action application="%s" data="%s"/>',
    xml_escape(app),
    xml_escape(data)
  )
end

local function extension_xml(name, destination, actions)
  return string.format(
    [[      <extension name="%s">
        <condition field="destination_number" expression="^%s$">
%s
        </condition>
      </extension>]],
    xml_escape(name),
    xml_escape(destination),
    table.concat(actions, "\n")
  )
end

local function context_xml(context, body)
  return string.format('    <context name="%s">\n%s\n    </context>', xml_escape(context), body)
end

--- Applies a route's digit manipulation, then builds the bridge string.
local function build_outbound(route, destination, tenant)
  local number = destination
  if route.stripDigits and route.stripDigits > 0 then
    number = number:sub(route.stripDigits + 1)
  end
  if route.prependDigits and route.prependDigits ~= "" then
    number = route.prependDigits .. number
  end

  local actions = {}

  -- Tenant identity must survive the B2BUA: FreeSWITCH rebuilds the INVITE, so $fU/$au do not
  -- reach Kamailio's egress pass. Without these headers per-tenant limits, trunk selection and
  -- CDR attribution all silently stop working at the trunk boundary.
  table.insert(actions, action("set", "sip_h_X-Tenant-ID=" .. (tenant.organizationId or "")))
  table.insert(actions, action("set", "sip_h_X-Auth-User=${sip_auth_username}"))
  table.insert(actions, action("set", "sip_h_X-Correlation-ID=${uuid}"))

  if route.isEmergency then
    -- Must be a SIP header, not just a channel variable: Kamailio's egress pass reads
    -- $hdr(X-Emergency) to skip the fraud checks, and a channel variable never reaches the
    -- wire. `emergency_call` is kept as well for the ESL listener that sends the Kari's Law
    -- notification, which reads channel data rather than SIP.
    table.insert(actions, action("set", "sip_h_X-Emergency=true"))
    table.insert(actions, action("set", "emergency_call=true"))
    table.insert(actions, action("set", "ignore_early_media=true"))
  end

  if route.callerIdOverride and route.callerIdOverride ~= "" then
    table.insert(actions, action("set", "effective_caller_id_number=" .. route.callerIdOverride))
  end

  table.insert(actions, action("set", "hangup_after_bridge=true"))

  -- Always out through Kamailio's egress port. FreeSWITCH never contacts a carrier directly -
  -- Kamailio is the only element that touches the internet.
  local egress = os.getenv("VOIP_KAM_EGRESS") or "127.0.0.1:5070"
  table.insert(actions, action("bridge", string.format("sofia/external/%s@%s", number, egress)))

  return actions
end

function M.dialplan(req, p)
  local destination = p:getHeader("Caller-Destination-Number")
    or p:getHeader("destination_number")
  local domain = p:getHeader("variable_sip_auth_realm")
    or p:getHeader("variable_domain_name")
    or p:getHeader("Caller-Context")

  if not destination or not domain then
    debug("dialplan request missing destination or domain - declining")
    return nil
  end

  local tenant = json_decode(redis_get("voip:tenant:" .. domain))
  if not tenant then
    log("warning", "dialplan MISS: no tenant for %s - falling through", domain)
    return nil
  end
  if tenant.enabled == false then
    log("warning", "tenant %s is disabled - rejecting", domain)
    return document(
      "dialplan",
      context_xml(
        "tenant_" .. tenant.organizationId,
        extension_xml("disabled", destination, { action("hangup", "SERVICE_UNAVAILABLE") })
      )
    )
  end

  local context = "tenant_" .. tenant.organizationId
  local routes = json_decode(redis_get("voip:routes:" .. domain)) or {}

  -- 1. Emergency, before anything that could block it.
  for _, route in ipairs(routes) do
    if route.isEmergency and destination:match(route.pattern) then
      log("notice", "EMERGENCY call to %s from %s", destination, domain)
      return document(
        "dialplan",
        context_xml(context, extension_xml("emergency", destination, build_outbound(route, destination, tenant)))
      )
    end
  end

  -- 2. Internal extension.
  local ext = redis_get("voip:dir:" .. domain .. ":" .. destination)
  if ext then
    return document(
      "dialplan",
      context_xml(
        context,
        extension_xml("internal", destination, {
          action("set", "hangup_after_bridge=true"),
          action("set", "continue_on_fail=true"),
          action("bridge", string.format("user/%s@%s", destination, domain)),
          action("answer", ""),
          action("voicemail", string.format("default %s %s", domain, destination)),
        })
      )
    )
  end

  --[[ 3. A stored destination - reached either by an inbound DID or by dialling a feature
       number internally. Both resolve to the same {type, id} pair, so they share one action
       builder; the call-time scripts in voip.lua handle everything past the first hop. ]]
  local function destination_actions(dtype, did_id)
    local actions = {}
    if dtype == "extension" then
      table.insert(actions, action("set", "hangup_after_bridge=true"))
      table.insert(actions, action("bridge", string.format("user/%s@%s", did_id, domain)))
    elseif dtype == "ivr" then
      table.insert(actions, action("answer", ""))
      table.insert(actions, action("lua", string.format("ivr.lua %s %s", domain, did_id)))
    elseif dtype == "ring_group" then
      table.insert(actions, action("lua", string.format("ring_group.lua %s %s", domain, did_id)))
    elseif dtype == "time_condition" then
      table.insert(actions, action("lua", string.format("time_condition.lua %s %s", domain, did_id)))
    elseif dtype == "fax" then
      table.insert(actions, action("answer", ""))
      table.insert(actions, action("playback", "silence_stream://2000"))
      table.insert(actions, action("lua", string.format("fax_receive.lua %s %s", domain, destination)))
    elseif dtype == "voicemail" then
      table.insert(actions, action("answer", ""))
      table.insert(actions, action("voicemail", string.format("default %s %s", domain, did_id)))
    else
      table.insert(actions, action("hangup", "UNALLOCATED_NUMBER"))
    end
    return actions
  end

  local did = json_decode(redis_get("voip:did:" .. domain .. ":" .. destination))
  if did then
    return document("dialplan", context_xml(context,
      extension_xml("did", destination, destination_actions(did.destinationType, did.destinationId))))
  end

  --[[ 3b. Feature number: the ring group or auto-attendant dialled from a desk phone inside
       the tenant. Checked after the directory so an extension always wins a number collision -
       a user who cannot be reached on their own extension is a worse failure than a ring group
       that needs renumbering. ]]
  local feature = json_decode(redis_get("voip:num:" .. domain .. ":" .. destination))
  if feature then
    return document("dialplan", context_xml(context,
      extension_xml("feature", destination, destination_actions(feature.type, feature.id))))
  end

  -- 4. Outbound. Non-emergency routes were already skipped above.
  for _, route in ipairs(routes) do
    if not route.isEmergency and destination:match(route.pattern) then
      if not route.trunk then
        log("warning", "route %s matched but has no trunk", route.id)
      else
        return document(
          "dialplan",
          context_xml(context, extension_xml("outbound", destination, build_outbound(route, destination, tenant)))
        )
      end
    end
  end

  debug("no route for %s@%s", destination, domain)
  return document(
    "dialplan",
    context_xml(context, extension_xml("no_route", destination, { action("hangup", "UNALLOCATED_NUMBER") }))
  )
end

--[[ ---------------------------------------------------------------------------------------
  Entry point
--------------------------------------------------------------------------------------- ]]

local section = XML_REQUEST["section"]
local result = nil

local ok, err = pcall(function()
  if section == "directory" then
    result = M.directory(XML_REQUEST, params)
  elseif section == "dialplan" then
    result = M.dialplan(XML_REQUEST, params)
  end
  -- `configuration` is deliberately unhandled: it is read at module load and reloadxml, not on
  -- the call path, so mod_xml_curl serves it from the API where the logic is easier to change.
end)

if not ok then
  -- Never let an error here become a failed call. Returning nothing makes FreeSWITCH try the
  -- next binding (mod_xml_curl), which is exactly the fallback this design relies on.
  log("err", "handler error: %s", tostring(err))
  result = nil
end

XML_STRING = result
