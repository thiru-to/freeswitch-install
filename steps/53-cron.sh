#!/usr/bin/env bash
### Scheduled maintenance. Timers rather than crontab entries, so failures land in the
### journal alongside everything else and can be inspected with systemctl.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

CDR_KEEP_DAYS="${CDR_KEEP_DAYS:-365}"
RECORDING_KEEP_DAYS="${RECORDING_KEEP_DAYS:-90}"

write_file /usr/local/sbin/voip-maintenance 0750 <<EOF || true
#!/usr/bin/env bash
# Managed by the VoIP PBX installer.
set -uo pipefail

PREFIX=/usr/local/freeswitch

### Stale registrations. Kamailio expires these itself, but a crash can leave rows behind
### that make endpoints look reachable when they are not.
if command -v kamctl >/dev/null 2>&1; then
  su - postgres -c "psql -q -d kamailio -c \"DELETE FROM location WHERE expires < NOW() - INTERVAL '1 day'\"" 2>/dev/null || true
fi

### CDR retention. Adjust CDR_KEEP_DAYS in /etc/voip-pbx/config.env - and check what your
### jurisdiction requires before shortening it.
find "\$PREFIX/log/cdr-csv" -name '*.csv.*' -mtime +${CDR_KEEP_DAYS} -delete 2>/dev/null || true

### Recordings are large and grow without bound.
find "\$PREFIX/recordings" -type f -mtime +${RECORDING_KEEP_DAYS} -delete 2>/dev/null || true
find "\$PREFIX/recordings" -type d -empty -delete 2>/dev/null || true

### FreeSWITCH's core db accumulates dead rows from every call leg.
su - postgres -c "psql -q -d voipapi -c 'VACUUM ANALYZE'" 2>/dev/null || true
su - postgres -c "psql -q -d kamailio -c 'VACUUM ANALYZE'" 2>/dev/null || true

### Old config backups left by write_file across many installer runs.
find /etc/voip-pbx /etc/kamailio /usr/local/freeswitch/conf \\
  -name '*.bak-*' -mtime +30 -delete 2>/dev/null || true

echo "maintenance complete"
EOF

write_file /etc/systemd/system/voip-maintenance.service 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=VoIP PBX scheduled maintenance
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/voip-maintenance
EnvironmentFile=-/etc/voip-pbx/config.env
Nice=15
IOSchedulingClass=idle
StandardOutput=journal
SyslogIdentifier=voip-maintenance
EOF

write_file /etc/systemd/system/voip-maintenance.timer 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=Nightly VoIP PBX maintenance

[Timer]
# After the backup, so anything pruned here is already captured.
OnCalendar=*-*-* 04:10:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now voip-maintenance.timer >/dev/null 2>&1 || true

info "Scheduled timers:"
systemctl list-timers --no-pager 'voip-*' 'certbot*' 2>/dev/null | head -6 | sed 's/^/  /' || true

ok "Maintenance scheduled (CDR ${CDR_KEEP_DAYS}d, recordings ${RECORDING_KEEP_DAYS}d)"
