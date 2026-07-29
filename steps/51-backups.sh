#!/usr/bin/env bash
### Nightly backups of the databases and configuration.
###
### Local-only by design. A backup on the same disk survives a bad deploy or a dropped table,
### but not a lost instance - wire OFFSITE_RSYNC_TARGET up before calling this done.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

BACKUP_DIR="${BACKUP_DIR:-/var/backups/voip-pbx}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

install -d -m 0700 -o root -g root "$BACKUP_DIR"

write_file /usr/local/sbin/voip-backup 0750 <<EOF || true
#!/usr/bin/env bash
# Managed by the VoIP PBX installer.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR}"
KEEP_DAYS="${BACKUP_KEEP_DAYS}"
STAMP="\$(date +%Y%m%d-%H%M%S)"
DEST="\$BACKUP_DIR/\$STAMP"
install -d -m 0700 "\$DEST"

fail=0

### Databases. --clean --if-exists makes each dump restorable over an existing database.
for db in kamailio voipapi; do
  if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='\$db'\"" | grep -q 1; then
    if su - postgres -c "pg_dump --clean --if-exists --format=custom '\$db'" > "\$DEST/\$db.dump" 2>/dev/null; then
      echo "dumped \$db (\$(du -h "\$DEST/\$db.dump" | cut -f1))"
    else
      echo "FAILED to dump \$db" >&2; fail=1
    fi
  fi
done

### Global objects (roles, and their passwords) are not in a per-database dump. Without this
### a restore comes back with no accounts able to log in.
su - postgres -c "pg_dumpall --globals-only" > "\$DEST/globals.sql" 2>/dev/null || { echo "FAILED globals" >&2; fail=1; }

### Configuration. Enough to rebuild the host from a fresh install plus this archive.
tar czf "\$DEST/config.tar.gz" \\
  --ignore-failed-read \\
  /etc/voip-pbx \\
  /etc/kamailio \\
  /etc/rtpengine \\
  /etc/nginx/sites-available \\
  /etc/nginx/conf.d \\
  /usr/local/freeswitch/conf \\
  /etc/systemd/system/freeswitch.service \\
  /etc/systemd/system/voip-api.service \\
  /etc/nftables.conf \\
  /etc/fail2ban/jail.d \\
  2>/dev/null || true

### The config archive contains database passwords and TLS keys.
chmod -R go-rwx "\$DEST"

### Retention. Only prune once the current run succeeded, so a failing backup job cannot
### quietly delete the last good copy.
if [ "\$fail" -eq 0 ]; then
  find "\$BACKUP_DIR" -maxdepth 1 -type d -name '20*' -mtime +\$KEEP_DAYS -exec rm -rf {} + 2>/dev/null || true
else
  echo "Backup had failures - skipping retention prune" >&2
fi

### Optional offsite copy.
if [ -n "\${OFFSITE_RSYNC_TARGET:-}" ]; then
  rsync -az --delete "\$BACKUP_DIR/" "\$OFFSITE_RSYNC_TARGET/" \\
    && echo "synced offsite" || { echo "offsite sync FAILED" >&2; fail=1; }
fi

echo "backup \$STAMP complete (\$(du -sh "\$DEST" | cut -f1))"
exit \$fail
EOF

write_file /etc/systemd/system/voip-backup.service 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=VoIP PBX backup
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/voip-backup
EnvironmentFile=-/etc/voip-pbx/config.env
Nice=10
IOSchedulingClass=idle
EOF

write_file /etc/systemd/system/voip-backup.timer 0644 <<'EOF' || true
[Unit]
# Managed by the VoIP PBX installer.
Description=Nightly VoIP PBX backup

[Timer]
OnCalendar=*-*-* 03:20:00
# Spread the load if several hosts share a backup target, and catch up after downtime.
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now voip-backup.timer >/dev/null 2>&1 || true

info "Running an initial backup to prove it works"
if /usr/local/sbin/voip-backup; then
  ok "Backup verified"
else
  warn "The first backup reported errors - check the output above."
fi

[ -n "${OFFSITE_RSYNC_TARGET:-}" ] || \
  warn "No OFFSITE_RSYNC_TARGET set - backups are on the same host they protect."

ok "Backups scheduled nightly at 03:20, ${BACKUP_KEEP_DAYS} day retention"
