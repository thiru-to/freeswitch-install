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
rm -f "$CONF/sip_profiles/external.xml" "$CONF/sip_profiles/internal-ipv6.xml" \
      "$CONF/sip_profiles/external-ipv6.xml" 2>/dev/null || true

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

chown -R freeswitch:freeswitch "$CONF"

### --- Apply ------------------------------------------------------------------------------

if systemctl is-active --quiet freeswitch; then
  restart_service freeswitch
  sleep 3
  if "$PREFIX/bin/fs_cli" -x "status" 2>/dev/null | grep -q "^UP"; then
    ok "FreeSWITCH reloaded"
    "$PREFIX/bin/fs_cli" -x "sofia status" 2>/dev/null | sed 's/^/  /' | head -8
  else
    die "FreeSWITCH did not come back after the config change."
  fi
else
  warn "FreeSWITCH is not running - configuration written, start it with: systemctl start freeswitch"
fi

ok "FreeSWITCH configured (ESL on 127.0.0.1:8021, SIP on 127.0.0.1:${FS_INTERNAL_SIP_PORT}, Opus preferred)"
