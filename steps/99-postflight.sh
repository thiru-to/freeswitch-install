#!/usr/bin/env bash
### Final verification. Checks the system actually works rather than that the installer ran.
###
### This step deliberately does not change anything - it only reports. A non-zero exit means
### the install completed but the result is not sound.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

PREFIX=/usr/local/freeswitch
problems=0
checks=0

check() {
  local label="$1"; shift
  checks=$((checks + 1))
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
    problems=$((problems + 1))
  fi
}

# shellcheck disable=SC2329 # invoked indirectly via check()
port_listening() {
  ss -ltnu 2>/dev/null | grep -qE "[:.]$1\b"
}

printf '\n--- Services ---\n'
for unit in postgresql redis-server freeswitch kamailio rtpengine nginx voip-api fail2ban nftables; do
  systemctl list-unit-files 2>/dev/null | grep -q "^${unit}" || continue
  check "$unit running" systemctl is-active --quiet "$unit"
done

printf '\n--- Listening ports ---\n'
check "SIP ${SIP_PORT}"            port_listening "$SIP_PORT"
check "FreeSWITCH ${FS_INTERNAL_SIP_PORT} (loopback)" port_listening "$FS_INTERNAL_SIP_PORT"
check "API ${API_PORT} (loopback)" port_listening "$API_PORT"
check "HTTPS 443"                  port_listening 443
check "Postgres 5432"              port_listening 5432

printf '\n--- Telephony ---\n'
if [ -x "$PREFIX/bin/fs_cli" ]; then
  check "FreeSWITCH responds on ESL" bash -c "$PREFIX/bin/fs_cli -x status | grep -q '^UP'"
  check "Opus codec loaded"          bash -c "$PREFIX/bin/fs_cli -x 'show codec' | grep -qi opus"
  check "SIP profile up"             bash -c "$PREFIX/bin/fs_cli -x 'sofia status' | grep -qi RUNNING"

  ### A clean boot log is a much stronger signal than 'the process is alive'.
  errs="$(grep -icE '\[(ERR|CRIT)\]' "$PREFIX/log/freeswitch.log" 2>/dev/null || echo 0)"
  checks=$((checks + 1))
  if [ "$errs" -eq 0 ]; then
    ok "No errors in the FreeSWITCH log"
  else
    fail "$errs [ERR]/[CRIT] lines in the FreeSWITCH log"
    grep -iE '\[(ERR|CRIT)\]' "$PREFIX/log/freeswitch.log" 2>/dev/null \
      | sed -E 's/^[0-9-]+ [0-9:.]+ [0-9.]+% //' | sort -u | head -5 | sed 's/^/      /'
    problems=$((problems + 1))
  fi
fi

check "Kamailio config valid" kamailio -c -f /etc/kamailio/kamailio.cfg
check "rtpengine control socket" bash -c "ss -lun | grep -q ':${RTPENGINE_NG_PORT}'"

printf '\n--- Security ---\n'
check "Firewall active"          bash -c "nft list ruleset | grep -q 'hook input'"
check "SSH root login disabled"  bash -c "sshd -T 2>/dev/null | grep -q '^permitrootlogin no'"
check "fail2ban jails loaded"    bash -c "fail2ban-client status | grep -q 'Jail list'"
check "Redis needs a password"   bash -c "! redis-cli ping 2>/dev/null | grep -q PONG"
check "Postgres is loopback-only" bash -c "! ss -ltn | grep ':5432' | grep -qv '127.0.0.1\|::1'"

printf '\n--- TLS ---\n'
CERT=/etc/voip-pbx/tls/fullchain.pem
if [ -f "$CERT" ]; then
  end="$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)"
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  checks=$((checks + 1))
  if [ "$days" -gt 14 ]; then
    ok "Certificate valid for ${days} more days"
  else
    fail "Certificate expires in ${days} days"
    problems=$((problems + 1))
  fi
  check "Certificate matches ${PBX_FQDN}" \
    bash -c "openssl x509 -noout -text -in '$CERT' | grep -q '${PBX_FQDN}'"
  check "Renewal timer enabled" systemctl is-enabled --quiet certbot.timer
else
  fail "No certificate at $CERT"
  problems=$((problems + 1)); checks=$((checks + 1))
fi

printf '\n--- Scheduled work ---\n'
for timer in voip-backup.timer voip-maintenance.timer voip-healthcheck.timer; do
  systemctl list-unit-files 2>/dev/null | grep -q "^${timer}" || continue
  check "$timer enabled" systemctl is-enabled --quiet "$timer"
done

printf '\n=================================================================\n'
if [ "$problems" -eq 0 ]; then
  ok "All ${checks} checks passed."
  printf '\n'
  info "SIP domain:  ${PBX_SIP_DOMAIN}"
  info "SIP:         ${PBX_FQDN}:${SIP_PORT} (UDP/TCP), ${SIPS_PORT} (TLS)"
  info "API:         https://${PBX_FQDN}/"
  info "Config:      ${CONFIG_FILE}"
  info "Health:      voip-healthcheck"
  printf '\n'
  warn "Still to do before taking real traffic:"
  warn "  - Create SIP subscribers (kamctl add <user>@${PBX_SIP_DOMAIN} <password>)"
  warn "  - Write the dialplan and outbound trunk routing"
  warn "  - Narrow ADMIN_ALLOW_CIDR if it is still 0.0.0.0/0"
  warn "  - Set OFFSITE_RSYNC_TARGET so backups leave this host"
  warn "  - Place a test call and confirm two-way audio"
  exit 0
else
  fail "${problems} of ${checks} checks failed."
  printf '\n'
  info "Investigate with: journalctl -xeu <unit>, or voip-healthcheck"
  exit 1
fi
