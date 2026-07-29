#!/usr/bin/env bash
### Log rotation. FreeSWITCH in particular will fill a disk given the chance, and a full disk
### on a PBX means dropped calls, not just missing logs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install logrotate

### FreeSWITCH keeps its log file open, so the file must be rotated in place (copytruncate)
### or the daemon told to reopen it. mod_logfile reopens on SIGHUP, which is cleaner because
### copytruncate can lose the lines written during the copy.
write_file /etc/logrotate.d/freeswitch 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
/usr/local/freeswitch/log/*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    create 0640 freeswitch freeswitch
    sharedscripts
    postrotate
        # mod_logfile reopens its file on HUP - no lines lost, no restart needed.
        /usr/local/freeswitch/bin/fs_cli -x 'fsctl send_sighup' >/dev/null 2>&1 || true
    endscript
}

/usr/local/freeswitch/log/cdr-csv/*.csv {
    daily
    rotate 90
    missingok
    notifempty
    compress
    delaycompress
    create 0640 freeswitch freeswitch
}
EOF

write_file /etc/logrotate.d/voip-nginx 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
/var/log/nginx/voip-*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)" || true
    endscript
}
EOF

### msmtp writes its own file rather than the journal - it runs as a one-shot child of whichever
### service is sending, so there is no unit to attribute the output to. One line per message,
### and it is the only record of a voicemail or fax that failed to deliver.
write_file /etc/logrotate.d/voip-msmtp 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
/var/log/msmtp.log {
    monthly
    rotate 12
    missingok
    notifempty
    compress
    delaycompress
    create 0660 root msmtp
}
EOF

### Kamailio, rtpengine and the API all log to the journal, so their retention is a journald
### setting rather than a logrotate one.
write_file /etc/systemd/journald.conf.d/90-voip.conf 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
SystemKeepFree=1G
MaxRetentionSec=30day
# Rate limiting off for telephony: a burst of SIP errors during an incident is exactly the
# data you need, and the default limiter silently discards it.
RateLimitIntervalSec=0
RateLimitBurst=0
EOF

systemctl restart systemd-journald

logrotate -d /etc/logrotate.d/freeswitch >/dev/null 2>&1 \
  || warn "logrotate reported a problem with the FreeSWITCH rule - check it manually."

ok "Log rotation configured (FreeSWITCH 30d, CDR 90d, journal 30d/2G)"
