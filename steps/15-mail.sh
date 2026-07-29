#!/usr/bin/env bash
### Outbound mail relay.
###
### Two v1 features deliver by email - voicemail-to-email and fax-to-email - and both reach the
### network the same way: they shell out to `sendmail -t`. FreeSWITCH's switch_simple_email()
### does it (switch_utils.c), and the API's fax delivery does it. Debian installs no MTA, so
### without this step both features record the message, log a line, and deliver nothing.
###
### msmtp rather than Postfix: a relay-only client with no listening daemon and no local queue
### is the whole requirement here. A full MTA on a SIP edge box is a spam-relay incident waiting
### for a misconfiguration, and it is one more thing to patch.
###
### Relay credentials are optional. Without SMTP_HOST the step installs nothing and says so -
### an operator evaluating the system should not have to set up email before they can make a
### call, and the two features degrade honestly (the recording is stored and downloadable).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

SMTP_HOST="${SMTP_HOST:-}"

if [ -z "$SMTP_HOST" ]; then
  warn "SMTP_HOST is not set - skipping mail relay setup."
  warn "  Voicemail-to-email and fax-to-email will store messages but not deliver them."
  warn "  Set SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASSWORD/SMTP_FROM in ${CONFIG_FILE} and"
  ### --force is not optional in that command: exiting 0 here leaves a completion marker, so a
  ### later run skips this step and the operator is left wondering why email still does nothing.
  warn "  re-run: ./install.sh --only 15-mail.sh --force"
  exit 0
fi

SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-pbx@${PBX_FQDN}}"
SMTP_STARTTLS="${SMTP_STARTTLS:-on}"

### msmtp-mta provides /usr/sbin/sendmail, which is the name both callers look for. Installing
### plain `msmtp` alone leaves that symlink absent and the whole step inert.
apt_install msmtp msmtp-mta

### 0640 root:msmtp: the relay password is in here, and both FreeSWITCH and the API invoke
### sendmail as their own service users, so the file has to be readable by the msmtp group
### rather than world-readable.
if ! getent group msmtp >/dev/null; then
  groupadd --system msmtp
fi

auth_lines="auth off"
if [ -n "$SMTP_USER" ]; then
  auth_lines="auth on
user ${SMTP_USER}
password ${SMTP_PASSWORD}"
fi

write_file /etc/msmtprc 0640 root:msmtp <<EOF || true
# Managed by the VoIP PBX installer.

defaults
# Certificate verification stays on. A relay that needs it disabled is a relay that cannot
# prove who it is, and voicemail recordings are customer content.
tls on
tls_starttls ${SMTP_STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host ${SMTP_HOST}
port ${SMTP_PORT}
from ${SMTP_FROM}
${auth_lines}
EOF

### msmtp refuses to run if the file is group- or world-writable, and reports it only in its own
### log - so assert it here rather than discovering it from an undelivered voicemail.
chmod 0640 /etc/msmtprc

### 0660, not 0640: msmtp runs as the calling service user and writes this log itself. Read-only
### for the group means every delivery failure is reported to a log nobody can write - so the
### operator is pointed at an empty file while mail silently disappears.
install -m 0660 -o root -g msmtp /dev/null /var/log/msmtp.log 2>/dev/null || true
chmod 0660 /var/log/msmtp.log

### Debian's msmtp-mta also ships msmtpd, a listening SMTP daemon. It arrives disabled, but this
### box is a SIP edge and has no business accepting mail from anywhere - mask it so it cannot be
### started by a later package action or an operator reading the wrong how-to.
systemctl mask msmtpd.service >/dev/null 2>&1 || true

### The service users that invoke sendmail. Each must be able to read /etc/msmtprc, which holds
### the relay password and is therefore group-readable rather than world-readable.
changed_users=""
for svc_user in freeswitch "${API_USER:-voipapi}"; do
  if id "$svc_user" >/dev/null 2>&1 && ! id -nG "$svc_user" | tr ' ' '\n' | grep -qx msmtp; then
    usermod -a -G msmtp "$svc_user"
    changed_users="$changed_users $svc_user"
    info "Added ${svc_user} to the msmtp group"
  fi
done

### Supplementary groups are read at process start, so a running service keeps the old set and
### gets "permission denied" on /etc/msmtprc until it is restarted. Silent, and it looks like a
### relay problem rather than a local one.
for svc in freeswitch voip-api; do
  if [ -n "$changed_users" ] && systemctl is-active --quiet "$svc"; then
    restart_service "$svc"
  fi
done

if [ ! -x /usr/sbin/sendmail ]; then
  die "msmtp-mta did not provide /usr/sbin/sendmail - voicemail and fax email will not work."
fi

ok "Mail relay configured: ${SMTP_HOST}:${SMTP_PORT} as ${SMTP_FROM}"
info "Test delivery with:"
info "  printf 'To: you@example.com\\nSubject: PBX test\\n\\nhello\\n' | /usr/sbin/sendmail -t"
info "Failures are logged to /var/log/msmtp.log, not to the journal."
