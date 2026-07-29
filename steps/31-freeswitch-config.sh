#!/usr/bin/env bash
### Production FreeSWITCH configuration.
###
### Topology: Kamailio owns the public SIP ports and forwards to FreeSWITCH on loopback.
### FreeSWITCH is therefore never directly exposed, which removes an entire class of
### internet-facing attack surface and lets Kamailio absorb scans and floods first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

PREFIX="/usr/local/freeswitch"
CONF="$PREFIX/conf"
[ -d "$CONF" ] || die "$CONF is missing - run 30-freeswitch.sh first."

config_ensure_secret FS_ESL_PASSWORD 32
config_ensure_secret FS_XML_GATEWAY_SECRET 32

### --- Modules that must be autoloaded -------------------------------------------------------

### These are all BUILT by 30-freeswitch.sh but none is in the minimal config's autoload list,
### and each fails differently and quietly when missing:
###   mod_lua      - no XML handler at all, so every lookup falls through to HTTP
###   mod_hiredis  - Lua cannot reach Redis; every call takes the slow path
###   mod_pgsql    - freeswitch.Dbh("pgsql://...") fails, so the Postgres fallback is dead
###   mod_spandsp  - fax silently does not answer
### The install asserts each one loaded at the end rather than trusting the config.
### mod_xml_curl and mod_curl are DIFFERENT modules with confusingly similar names:
###   mod_xml_curl - the XML gateway; this is the fallback binding. Without it the whole
###                  fall-through tier is inert and a Redis miss resolves to nothing.
###   mod_curl     - an HTTP client for Lua and the dialplan. Not a fallback for anything.
FS_AUTOLOAD_ADD="mod_opus mod_lua mod_hiredis mod_pgsql mod_spandsp mod_voicemail mod_curl mod_xml_curl"

### --- Event socket -----------------------------------------------------------------------

### The stock config listens on "::". On a host without IPv6 that fails to bind outright, and
### where it does work it exposes the control socket far wider than intended. ESL is a full
### remote-control channel for the switch - it belongs on loopback with a real password.
write_file "$CONF/autoload_configs/event_socket.conf.xml" 0644 freeswitch:freeswitch <<EOF || true
<configuration name="event_socket.conf" description="Socket Client">
  <settings>
    <param name="nat-map" value="false"/>
    <param name="listen-ip" value="127.0.0.1"/>
    <param name="listen-port" value="8021"/>
    <param name="password" value="${FS_ESL_PASSWORD}"/>
    <param name="apply-inbound-acl" value="loopback.auto"/>
  </settings>
</configuration>
EOF

### fs_cli defaults to the stock "ClueCon" password, so once ESL has a generated one every
### fs_cli invocation fails with "Error Connecting" - including the ones this installer uses to
### verify the result, and every one an operator types. fs_cli reads /etc/fs_cli.conf, so
### writing it here fixes both at once.
write_file /etc/fs_cli.conf 0600 root:root <<EOF || true
# Managed by the VoIP PBX installer. Contains the ESL password - root only.
[default]
host     => 127.0.0.1
port     => 8021
password => ${FS_ESL_PASSWORD}
debug    => 4
EOF

### --- Codecs and globals ------------------------------------------------------------------

### Opus first for WiFi/mobile, then G.711 for PSTN interop. G.722 sits between them as a
### wideband fallback for endpoints that cannot do Opus.
write_file "$CONF/vars.xml" 0644 freeswitch:freeswitch <<EOF || true
<include>
  <!-- Managed by the VoIP PBX installer. -->

  <X-PRE-PROCESS cmd="set" data="domain=${PBX_SIP_DOMAIN}"/>
  <X-PRE-PROCESS cmd="set" data="domain_name=\$\${domain}"/>
  <X-PRE-PROCESS cmd="set" data="hostname=${PBX_FQDN}"/>

  <!-- FreeSWITCH sits behind Kamailio on loopback. -->
  <X-PRE-PROCESS cmd="set" data="internal_sip_ip=127.0.0.1"/>
  <X-PRE-PROCESS cmd="set" data="internal_sip_port=${FS_INTERNAL_SIP_PORT}"/>

  <!-- Media addresses. auto-nat is off: rtpengine handles NAT, and letting FreeSWITCH
       also rewrite SDP produces two components fighting over the same fields. -->
  <X-PRE-PROCESS cmd="set" data="external_rtp_ip=\$\${local_ip_v4}"/>
  <X-PRE-PROCESS cmd="set" data="external_sip_ip=\$\${local_ip_v4}"/>

  <X-PRE-PROCESS cmd="set" data="global_codec_prefs=OPUS,G722,PCMU,PCMA"/>
  <X-PRE-PROCESS cmd="set" data="outbound_codec_prefs=OPUS,G722,PCMU,PCMA"/>

  <X-PRE-PROCESS cmd="set" data="rtp_video_max_bandwidth_in=0"/>
  <X-PRE-PROCESS cmd="set" data="sound_prefix=\$\${sounds_dir}/en/us/callie"/>

  <!-- Recording and voicemail formats. wav keeps CPU free; transcode later if you need it. -->
  <X-PRE-PROCESS cmd="set" data="recording_format=wav"/>

  <X-PRE-PROCESS cmd="set" data="rtp_start_port=${RTP_PORT_MIN}"/>
  <X-PRE-PROCESS cmd="set" data="rtp_end_port=${RTP_PORT_MAX}"/>
</include>
EOF

### --- ACLs ------------------------------------------------------------------------------

### Only Kamailio (loopback) may send SIP to FreeSWITCH. Anything else is rejected before it
### reaches the dialplan.
write_file "$CONF/autoload_configs/acl.conf.xml" 0644 freeswitch:freeswitch <<'EOF' || true
<configuration name="acl.conf" description="Network Lists">
  <network-lists>
    <!-- Managed by the VoIP PBX installer. -->
    <list name="trusted" default="deny">
      <node type="allow" cidr="127.0.0.0/8"/>
      <node type="allow" cidr="::1/128"/>
    </list>
    <list name="loopback.auto" default="deny">
      <node type="allow" cidr="127.0.0.0/8"/>
      <node type="allow" cidr="::1/128"/>
    </list>
  </network-lists>
</configuration>
EOF

### --- SIP profile -------------------------------------------------------------------------

### One internal profile bound to loopback. Authentication happens at Kamailio, so this
### profile trusts what reaches it (accept-blind-auth) but only accepts it from the trusted
### ACL above - that pairing is what makes it safe.
install -d -m 0755 -o freeswitch -g freeswitch "$CONF/sip_profiles"
rm -f "$CONF/sip_profiles/internal-ipv6.xml" "$CONF/sip_profiles/external-ipv6.xml" \
      2>/dev/null || true

write_file "$CONF/sip_profiles/internal.xml" 0644 freeswitch:freeswitch <<EOF || true
<profile name="internal">
  <!-- Managed by the VoIP PBX installer. Fed by Kamailio over loopback. -->
  <settings>
    <param name="sip-ip" value="127.0.0.1"/>
    <param name="sip-port" value="${FS_INTERNAL_SIP_PORT}"/>
    <param name="rtp-ip" value="\$\${local_ip_v4}"/>
    <param name="context" value="default"/>
    <param name="dialplan" value="XML"/>
    <param name="user-agent-string" value="VoIP PBX"/>

    <param name="apply-inbound-acl" value="trusted"/>
    <param name="auth-calls" value="false"/>
    <param name="accept-blind-auth" value="true"/>
    <param name="accept-blind-reg" value="false"/>

    <param name="inbound-codec-prefs" value="\$\${global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="\$\${outbound_codec_prefs}"/>
    <param name="inbound-late-negotiation" value="true"/>
    <param name="inbound-zrtp-passthru" value="true"/>

    <!-- rtpengine owns NAT handling; FreeSWITCH must not second-guess the SDP. -->
    <param name="aggressive-nat-detection" value="false"/>
    <param name="apply-nat-acl" value="none"/>
    <param name="NDLB-received-in-nat-reg-contact" value="false"/>

    <param name="rtp-timeout-sec" value="300"/>
    <param name="rtp-hold-timeout-sec" value="1800"/>
    <param name="rtp-timer-name" value="soft"/>

    <param name="manage-presence" value="false"/>
    <param name="enable-100rel" value="true"/>
    <param name="disable-transcoding" value="false"/>
    <param name="log-auth-failures" value="true"/>
  </settings>
</profile>
EOF

### --- Egress profile -------------------------------------------------------------------------

### The outbound leg back to Kamailio. A SEPARATE profile from `internal` on purpose: it is one
### of the two independent signals (alongside KAM_EGRESS_PORT) that let Kamailio tell its
### ingress pass from its egress pass. Kamailio sees every call twice, and confusing the two is
### what produces double dialog counting and duplicate CDRs.
###
### FreeSWITCH still binds loopback here. It never contacts a carrier - Kamailio is the only
### element that touches the internet.
write_file "$CONF/sip_profiles/external.xml" 0644 freeswitch:freeswitch <<EOF || true
<profile name="external">
  <!-- Managed by the VoIP PBX installer. Outbound leg to Kamailio's egress listener. -->
  <gateways>
    <gateway name="kamailio-egress">
      <param name="realm" value="${FS_HOST}:${KAM_EGRESS_PORT}"/>
      <param name="proxy" value="${FS_HOST}:${KAM_EGRESS_PORT}"/>
      <!-- No registration: Kamailio trusts this peer by address, and a registering gateway
           here would produce loops. -->
      <param name="register" value="false"/>
      <param name="context" value="egress"/>
    </gateway>
  </gateways>
  <settings>
    <param name="sip-ip" value="127.0.0.1"/>
    <param name="sip-port" value="$((FS_INTERNAL_SIP_PORT + 1))"/>
    <param name="rtp-ip" value="\$\${local_ip_v4}"/>
    <param name="context" value="egress"/>
    <param name="dialplan" value="XML"/>
    <param name="user-agent-string" value="VoIP PBX"/>

    <param name="auth-calls" value="false"/>
    <param name="apply-inbound-acl" value="trusted"/>

    <param name="inbound-codec-prefs" value="\$\${global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="\$\${outbound_codec_prefs}"/>
    <param name="inbound-late-negotiation" value="true"/>

    <!-- rtpengine relays this leg too, so the carrier never sees FreeSWITCH's address and the
         GCE private-IP-behind-NAT problem does not arise. -->
    <param name="aggressive-nat-detection" value="false"/>
    <param name="apply-nat-acl" value="none"/>

    <param name="rtp-timeout-sec" value="300"/>
    <param name="log-auth-failures" value="true"/>
  </settings>
</profile>
EOF

### --- Logging ----------------------------------------------------------------------------

### Default console logging is extremely chatty. Keep the file log at info and let 50-logrotate
### handle retention.
write_file "$CONF/autoload_configs/logfile.conf.xml" 0644 freeswitch:freeswitch <<'EOF' || true
<configuration name="logfile.conf" description="File Logging">
  <settings>
    <param name="rotate-on-hup" value="true"/>
  </settings>
  <profiles>
    <profile name="default">
      <settings>
        <param name="logfile" value="/usr/local/freeswitch/log/freeswitch.log"/>
        <param name="rollover" value="0"/>
        <param name="maximum-rotate" value="0"/>
      </settings>
      <mappings>
        <map name="all" value="console,info,notice,warning,err,crit,alert"/>
      </mappings>
    </profile>
  </profiles>
</configuration>
EOF

### --- Lua XML handler ----------------------------------------------------------------------

### This is the hot path. mod_lua binds through switch_xml_bind_search_function - the same
### mechanism mod_xml_curl uses - so lookups are served in-process from Redis instead of over
### HTTP. The API can be down or mid-deploy and calls keep flowing.
install -d -m 0755 -o freeswitch -g freeswitch "$PREFIX/scripts"
install -m 0644 -o freeswitch -g freeswitch \
  "$REPO_DIR/resources/lua/xml_handler.lua" "$PREFIX/scripts/xml_handler.lua"

write_file "$CONF/autoload_configs/lua.conf.xml" 0644 freeswitch:freeswitch <<EOF || true
<configuration name="lua.conf" description="LUA Configuration">
  <settings>
    <param name="script-directory" value="${PREFIX}/scripts/?.lua"/>
    <param name="xml-handler-script" value="xml_handler.lua"/>
    <!-- 'configuration' is deliberately absent: it is read at module load and reloadxml, not
         on the call path, so mod_xml_curl serves it from the API where it is easier to change. -->
    <param name="xml-handler-bindings" value="directory,dialplan"/>
  </settings>
</configuration>
EOF

### The Lua handler reads these from the environment rather than having them baked in, so a
### credential rotation does not mean editing a script.
install -d -m 0755 /etc/systemd/system/freeswitch.service.d
write_file /etc/systemd/system/freeswitch.service.d/10-voip-env.conf 0644 <<EOF || true
# Managed by the VoIP PBX installer.
[Service]
Environment=VOIP_PG_DSN=pgsql://host=${DB_HOST} port=${DB_PORT} dbname=voipapi user=${API_USER} password=${API_DB_PASSWORD}
Environment=VOIP_KAM_EGRESS=${FS_HOST}:${KAM_EGRESS_PORT}
EOF
systemctl daemon-reload

### --- Redis client --------------------------------------------------------------------------

### timeout_ms is deliberately tight. hiredis_profile_execute_sync is synchronous, so a Redis
### call from Lua blocks call setup; 200ms bounds that, and the handler falls through to
### Postgres and then mod_xml_curl rather than stalling.
write_file "$CONF/autoload_configs/hiredis.conf.xml" 0640 freeswitch:freeswitch <<EOF || true
<configuration name="hiredis.conf" description="mod_hiredis">
  <profiles>
    <profile name="default">
      <connections>
        <connection name="primary">
          <param name="hostname" value="${REDIS_HOST}"/>
          <param name="password" value="${REDIS_PASSWORD:-}"/>
          <param name="port" value="${REDIS_PORT}"/>
          <param name="timeout_ms" value="200"/>
        </connection>
      </connections>
      <params>
        <!-- Do not refuse to start if Redis is down: the Lua handler degrades to Postgres and
             then to mod_xml_curl, which is the whole point of the fall-through chain. -->
        <param name="ignore-connect-fail" value="true"/>
      </params>
    </profile>
  </profiles>
</configuration>
EOF

### --- xml_curl, bound second ------------------------------------------------------------------

### Bindings fall through: switch_xml.c loops over them and continues past any that returns
### NULL or status="not found". Lua is registered first (mod_lua loads earlier), so this only
### answers when Lua missed or errored.
write_file "$CONF/autoload_configs/xml_curl.conf.xml" 0640 freeswitch:freeswitch <<EOF || true
<configuration name="xml_curl.conf" description="cURL XML Gateway">
  <bindings>
    <binding name="api_fallback">
      <param name="gateway-url" value="${API_BASE_URL}/fs/xml" bindings="directory|dialplan|configuration"/>
      <param name="gateway-credentials" value="fs:${FS_XML_GATEWAY_SECRET}"/>
      <param name="auth-scheme" value="basic"/>
      <!-- Fail fast. A hung API must not wedge call setup - there is a static fallback below. -->
      <param name="timeout" value="3"/>
    </binding>
  </bindings>
</configuration>
EOF

### --- Autoload ------------------------------------------------------------------------------

FS_AUTOLOAD_CONF="$CONF/autoload_configs/modules.conf.xml"
for mod_name in $FS_AUTOLOAD_ADD; do
  if [ ! -f "$PREFIX/mod/${mod_name}.so" ]; then
    warn "${mod_name}.so was not built - skipping autoload"
    continue
  fi
  if grep -q "<load module=\"${mod_name}\"/>" "$FS_AUTOLOAD_CONF"; then
    continue
  fi
  ### A module's own config comes from the vanilla tree; the minimal config does not ship it.
  conf_name="${mod_name#mod_}.conf.xml"
  src_conf="/usr/src/freeswitch/conf/vanilla/autoload_configs/$conf_name"
  if [ -f "$src_conf" ] && [ ! -f "$CONF/autoload_configs/$conf_name" ]; then
    install -m 0644 -o freeswitch -g freeswitch "$src_conf" "$CONF/autoload_configs/$conf_name"
    info "Installed $conf_name from the vanilla config"
  fi
  sed -i "s|<!-- Codec Interfaces -->|<!-- Codec Interfaces -->\n    <load module=\"${mod_name}\"/>|" \
    "$FS_AUTOLOAD_CONF"
  info "Autoloaded ${mod_name}"
done

chown -R freeswitch:freeswitch "$CONF"

### --- Apply ------------------------------------------------------------------------------

if systemctl is-active --quiet freeswitch; then
  restart_service freeswitch
  sleep 4
  if ! "$PREFIX/bin/fs_cli" -p "$FS_ESL_PASSWORD" -x "status" 2>/dev/null | grep -q "^UP"; then
    die "FreeSWITCH did not come back after the config change."
  fi
  ok "FreeSWITCH reloaded"

  ### Assert each module actually loaded. This is the check that catches the trap these four
  ### share: built, referenced in config, and silently absent at runtime.
  missing=0
  for mod_name in $FS_AUTOLOAD_ADD; do
    if [ "$("$PREFIX/bin/fs_cli" -p "$FS_ESL_PASSWORD" -x "module_exists ${mod_name}" 2>/dev/null)" = "true" ]; then
      ok "  ${mod_name} loaded"
    else
      fail "  ${mod_name} did NOT load"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] || die "$missing module(s) failed to load - check: fs_cli -x 'load mod_x'"

  "$PREFIX/bin/fs_cli" -p "$FS_ESL_PASSWORD" -x "sofia status" 2>/dev/null | sed 's/^/  /' | head -8
else
  warn "FreeSWITCH is not running - configuration written, start it with: systemctl start freeswitch"
fi

ok "FreeSWITCH configured (Lua XML handler primary, xml_curl fallback, Redis on ${REDIS_HOST})"

ok "FreeSWITCH configured (ESL on 127.0.0.1:8021, SIP on 127.0.0.1:${FS_INTERNAL_SIP_PORT}, Opus preferred)"
