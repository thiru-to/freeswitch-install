#!/usr/bin/env bash
### Health checking and metrics.
###
### A PBX fails quietly: registrations stop refreshing, or calls connect with no audio, and
### nothing crashes. These checks look at whether the system is doing its job, not just
### whether the processes exist.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install prometheus-node-exporter

### Bind the exporter to loopback. Metrics leak a lot about a host and it has no auth.
ensure_directive /etc/default/prometheus-node-exporter "ARGS" \
  '"--web.listen-address=127.0.0.1:9100"' "="
systemctl restart prometheus-node-exporter 2>/dev/null || true
enable_service prometheus-node-exporter

### --- Health check --------------------------------------------------------------------------

write_file /usr/local/sbin/voip-healthcheck 0755 <<EOF || true
#!/usr/bin/env bash
# Managed by the VoIP PBX installer.
# Exit 0 = healthy, 1 = degraded. Suitable for a monitoring agent or cron alert.
set -uo pipefail

PREFIX=/usr/local/freeswitch
problems=0
report() { printf '%-22s %s\n' "\$1" "\$2"; }

### Services that must be running.
for unit in postgresql redis-server freeswitch kamailio rtpengine nginx voip-api; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^\${unit}"; then
    if systemctl is-active --quiet "\$unit"; then
      report "\$unit" "active"
    else
      report "\$unit" "DOWN"; problems=\$((problems+1))
    fi
  fi
done

### FreeSWITCH answering on ESL means it is genuinely up, not merely a live process.
if [ -x "\$PREFIX/bin/fs_cli" ]; then
  if "\$PREFIX/bin/fs_cli" -x status 2>/dev/null | grep -q '^UP'; then
    calls="\$("\$PREFIX/bin/fs_cli" -x 'show calls count' 2>/dev/null | head -1)"
    report "freeswitch esl" "responding (\${calls:-0 calls})"
  else
    report "freeswitch esl" "NOT RESPONDING"; problems=\$((problems+1))
  fi
fi

### Kamailio holding registrations. Zero is normal on a fresh install but worth surfacing -
### on a live system it means every endpoint has silently dropped off.
if command -v kamctl >/dev/null 2>&1; then
  regs="\$(kamctl ul show 2>/dev/null | grep -c 'AOR' || echo 0)"
  report "registrations" "\$regs"
fi

### SIP port actually bound.
if ss -lun 2>/dev/null | grep -q ":${SIP_PORT}\b" || ss -ltn 2>/dev/null | grep -q ":${SIP_PORT}\b"; then
  report "sip :${SIP_PORT}" "listening"
else
  report "sip :${SIP_PORT}" "NOT LISTENING"; problems=\$((problems+1))
fi

### Certificate expiry - the classic silent 90-day outage.
CERT=/etc/voip-pbx/tls/fullchain.pem
if [ -f "\$CERT" ]; then
  end="\$(openssl x509 -enddate -noout -in "\$CERT" 2>/dev/null | cut -d= -f2)"
  days=\$(( ( \$(date -d "\$end" +%s) - \$(date +%s) ) / 86400 ))
  if [ "\$days" -lt 14 ]; then
    report "tls certificate" "EXPIRES IN \${days}d"; problems=\$((problems+1))
  else
    report "tls certificate" "\${days}d remaining"
  fi
fi

### Disk. A full disk on a PBX drops calls.
use="\$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "\$use" -gt 85 ]; then
  report "disk /" "\${use}% FULL"; problems=\$((problems+1))
else
  report "disk /" "\${use}% used"
fi

### fail2ban bans, as a rough measure of how much abuse is arriving.
if command -v fail2ban-client >/dev/null 2>&1; then
  banned="\$(fail2ban-client banned 2>/dev/null | grep -o "'" | wc -l)"
  report "fail2ban" "\$(( banned / 2 )) banned"
fi

if [ "\$problems" -gt 0 ]; then
  echo
  echo "\$problems problem(s) detected"
  exit 1
fi
echo
echo "All checks passed"
exit 0
EOF

### Run it on a timer and let failures surface through the journal, where an existing
### monitoring agent can pick them up without this script needing to know about your alerting.
write_file /etc/systemd/system/voip-healthcheck.service 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=VoIP PBX health check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/voip-healthcheck
StandardOutput=journal
StandardError=journal
SyslogIdentifier=voip-health
EOF

write_file /etc/systemd/system/voip-healthcheck.timer 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=Run the VoIP PBX health check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now voip-healthcheck.timer >/dev/null 2>&1 || true

info "Current health:"
/usr/local/sbin/voip-healthcheck 2>&1 | sed 's/^/  /' || true

ok "Monitoring configured (node_exporter on 127.0.0.1:9100, health check every 5min)"
warn "Nothing alerts yet - point your monitoring at the exporter and the voip-health journal identifier."
