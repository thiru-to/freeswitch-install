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

### Enumerate ONCE into a variable rather than piping systemctl into `grep -q` per unit.
### `grep -q` exits at the first match, systemctl is killed by SIGPIPE, and under `pipefail`
### the pipeline reports failure - so `|| continue` silently skipped every single service
### check while the section still printed as if it had passed. Nothing is worse in a
### verification step than one that quietly checks nothing.
UNIT_FILES="$(systemctl list-unit-files --no-legend 2>/dev/null || true)"

printf '\n--- Services ---\n'
for unit in postgresql redis-server freeswitch kamailio rtpengine-daemon nginx voip-api fail2ban nftables; do
  case "$UNIT_FILES" in
    *"${unit}.service"*) : ;;
    *) continue ;;
  esac
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
  check "FreeSWITCH responds on ESL" bash -c "$PREFIX/bin/fs_cli -p $FS_ESL_PASSWORD -x status | grep -q '^UP'"
  check "Opus codec loaded"          bash -c "$PREFIX/bin/fs_cli -p $FS_ESL_PASSWORD -x 'show codec' | grep -qi opus"
  check "SIP profile up"             bash -c "$PREFIX/bin/fs_cli -p $FS_ESL_PASSWORD -x 'sofia status' | grep -qi RUNNING"

  ### A clean boot log is a much stronger signal than 'the process is alive'.
  ###
  ### Scoped to the CURRENT run, not the whole file. FreeSWITCH appends across restarts, so the
  ### unscoped version reported errors from a previous life for as long as the file survived -
  ### and it reliably failed a perfectly good install, because FreeSWITCH starts at step 30 and
  ### anything it depends on that is installed later logs an error in the meantime. An error
  ### from a run that has already been restarted away is history, not a finding.
  ###
  ### The comparison is lexicographic on 'YYYY-MM-DD HH:MM:SS', which sorts correctly and needs
  ### no epoch arithmetic - mawk (Debian's default awk) has no mktime(). Both sides are local
  ### time: FreeSWITCH logs local, and `date -d` renders systemd's timestamp as local.
  fs_since=""
  if fs_started="$(systemctl show freeswitch -p ActiveEnterTimestamp --value 2>/dev/null)" \
     && [ -n "$fs_started" ]; then
    fs_since="$(date -d "$fs_started" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  fi

  ### No timestamp available (FreeSWITCH not under systemd, or an unparseable value): fall back
  ### to the whole file rather than skipping the check. Over-reporting is the safe direction.
  fs_log_errors() {
    if [ -n "$fs_since" ]; then
      ### The timestamp prefix is required, not assumed. The log also carries untimestamped
      ### console output (the startup banner, module lists), and comparing those first 19
      ### characters against a date puts every one of them inside the window - letters sort
      ### above digits. Every level-tagged line does carry a timestamp, so this loses nothing.
      awk -v since="$fs_since" \
        '/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ && /\[(ERR|CRIT)\]/ \
           && (substr($0, 1, 19) "") >= (since "")' \
        "$PREFIX/log/freeswitch.log" 2>/dev/null || true
    else
      grep -aE '\[(ERR|CRIT)\]' "$PREFIX/log/freeswitch.log" 2>/dev/null || true
    fi
  }

  errs="$(fs_log_errors | grep -c . || true)"
  errs="${errs:-0}"
  checks=$((checks + 1))
  if [ "$errs" -eq 0 ]; then
    ok "No errors in the FreeSWITCH log"
  else
    fail "$errs [ERR]/[CRIT] lines in the FreeSWITCH log since it started"
    fs_log_errors | sed -E 's/^[0-9-]+ [0-9:.]+ [0-9.]+% //' | sort -u | head -5 | sed 's/^/      /'
    problems=$((problems + 1))
  fi
fi

check "Kamailio config valid" kamailio -c -f /etc/kamailio/kamailio.cfg
check "rtpengine control socket" bash -c "ss -lun | grep -q ':${RTPENGINE_NG_PORT}'"

if [ "${ENABLE_WEBRTC:-1}" = "1" ]; then
  check "WSS ${WSS_PORT} listening" port_listening "${WSS_PORT}"
  ### A browser refuses a WSS socket whose certificate does not match, so this is worth
  ### checking separately from the port being open.
  check "WSS presents a valid certificate" \
    bash -c "echo | openssl s_client -connect 127.0.0.1:${WSS_PORT} -servername ${PBX_FQDN} 2>/dev/null | grep -q 'Verify return code: 0'"
fi

if [ "${ENABLE_STIR_SHAKEN:-0}" = "1" ]; then
  mp="$(dirname "$(find /usr/lib -name 'tm.so' -path '*kamailio*' 2>/dev/null | head -1)")"
  check "stirshaken module built" test -f "$mp/stirshaken.so"
  check "STIR signing key present" test -f "${STIR_SHAKEN_KEY:-/etc/voip-pbx/stir/signing.key}"
  check "STIR CA roots present" bash -c "[ -n \"\$(ls -A /etc/voip-pbx/stir/ca 2>/dev/null)\" ]"
fi

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
  case "$UNIT_FILES" in *"${timer}"*) : ;; *) continue ;; esac
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
