#!/usr/bin/env bash
#
# Master installer for the VoIP PBX stack.
#
# Runs the numbered step scripts in order. Safe to re-run: each step records a marker keyed
# on the script's own checksum, so a completed step is skipped until its script changes.
# Everything is logged to /var/log/voip-install/.
#
# Usage:
#   sudo ./install.sh                 # run every pending step
#   sudo ./install.sh --list          # show the plan and each step's state
#   sudo ./install.sh --only 30-freeswitch.sh
#   sudo ./install.sh --from 40-bun.sh
#   sudo ./install.sh --force         # ignore markers, re-run everything
#   sudo ./install.sh --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP_DIR="$SCRIPT_DIR/steps"
LOG_DIR="/var/log/voip-install"
STATE_DIR="/var/lib/voip-install"

### The install order. Dependencies flow downwards - do not reorder without checking that
### nothing later depends on something earlier (Kamailio needs its database; the API needs
### Bun and Postgres; TLS certs must exist before anything binds a TLS port).
###
### Format: "script|roles|description". A step runs when ROLES contains "all", when the
### step's role is "all", or when the step's role appears in ROLES. The all-in-one machine
### is simply ROLES="all" - the degenerate case where every role lands on one host.
###
### Roles:
###   all     - host-level work every machine needs regardless of what it runs
###   db      - PostgreSQL and Redis
###   sip     - Kamailio and rtpengine (the SIP edge)
###   media   - FreeSWITCH (the media/PBX core)
###   portal  - the API, the web portal and nginx
STEPS=(
  "00-preflight.sh|all|Host validation, hostname/FQDN, timezone, NTP, kernel and limit tuning"
  "01-base-packages.sh|all|Common tooling, CA certificates, unattended security upgrades"

  "10-ssh-hardening.sh|all|Key-only SSH, no root login, restricted auth"
  "11-firewall.sh|all|nftables: default deny, SIP/RTP/HTTPS allowlist, SIP rate limiting"
  "12-fail2ban.sh|all|Jails for sshd, FreeSWITCH (mod_fail2ban) and Kamailio"
  "13-tls-certs.sh|all|Let's Encrypt certificates + renewal hooks for SIP TLS, WSS and the API"
  "14-responsive-firewall.sh|sip|Reputation-tiered SIP rate limiting, learned from live registrations"

  "20-postgresql.sh|db|PostgreSQL 18 from PGDG, pg_hba, tuning, WAL/backup prep"
  "21-redis.sh|db|Redis for mod_hiredis and API caching"
  "22-provision-databases.sh|db|Roles and databases for Kamailio and the API, least privilege"

  "30-freeswitch.sh|media|FreeSWITCH from source (media server / PBX core)"
  "31-freeswitch-config.sh|media|SIP profiles, ACLs, xml_curl + Lua, Opus codec preference"
  "32-kamailio.sh|sip|Kamailio 6.1 from deb.kamailio.org with postgres/tls/lua modules"
  "33-stir-shaken.sh|sip|STIR/SHAKEN caller attestation (source build; off by default)"
  "34-kamailio-config.sh|sip|Registrar, multi-tenant routing, WebRTC/WSS, dispatcher, schema"
  "35-rtpengine.sh|sip|RTP relay and WebRTC media bridging (DTLS-SRTP <-> RTP)"

  "40-bun.sh|portal|Bun runtime"
  "41-api-deploy.sh|portal media|Hono API build, Drizzle migrations, systemd unit, secrets"
  "42-nginx.sh|portal|TLS reverse proxy for the API and WSS"
  "43-portal-web.sh|portal|Build the React admin portal and publish it for nginx"

  "50-logrotate.sh|all|Rotation and retention for FreeSWITCH, Kamailio and API logs"
  "51-backups.sh|db|Scheduled pg_dump plus config snapshots, with retention"
  "52-monitoring.sh|all|Health checks, metrics exporter, alerting"
  "53-cron.sh|db|Scheduled maintenance (CDR rollup, cleanup)"

  "99-postflight.sh|all|Verify services, listening ports, TLS validity; print summary"
)

### ----------------------------------------------------------------------------------------
### Helpers
### ----------------------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()   { printf '%s %s\n'   "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info()  { log "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()    { log "${C_GREEN}[OK]${C_RESET}    $*"; }
warn()  { log "${C_YELLOW}[WARN]${C_RESET}  $*"; }
fail()  { log "${C_RED}[ERROR]${C_RESET} $*" >&2; }

die() { fail "$*"; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

### ----------------------------------------------------------------------------------------
### Argument parsing
### ----------------------------------------------------------------------------------------

DO_LIST=0; DO_FORCE=0; DO_DRYRUN=0; ONLY_STEP=""; FROM_STEP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list)    DO_LIST=1 ;;
    --force)   DO_FORCE=1 ;;
    --dry-run) DO_DRYRUN=1 ;;
    --only)    ONLY_STEP="${2:-}"; [ -n "$ONLY_STEP" ] || die "--only needs a step name"; shift ;;
    --from)    FROM_STEP="${2:-}"; [ -n "$FROM_STEP" ] || die "--from needs a step name"; shift ;;
    -h|--help) usage ;;
    *)         die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done

step_name()  { printf '%s' "${1%%|*}"; }
step_desc()  { printf '%s' "${1##*|}"; }
step_roles() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }

### Which roles this machine plays. Read from the deployed config so --list works before the
### installer has ever run; "all" (the all-in-one case) is the default.
ROLES="all"
if [ -r /etc/voip-pbx/config.env ]; then
  ROLES="$(sed -n 's/^ROLES=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}.*/\1/p' \
    /etc/voip-pbx/config.env | tail -1)"
  [ -n "$ROLES" ] || ROLES="all"
fi

### A step runs when this host is all-in-one, when the step applies to every host regardless
### of role, or when any of the step's roles is one this host plays.
step_applies() {
  local roles="$1" r h
  case " $ROLES " in *" all "*) return 0 ;; esac
  case " $roles " in *" all "*) return 0 ;; esac
  for r in $roles; do
    for h in $ROLES; do
      [ "$r" = "$h" ] && return 0
    done
  done
  return 1
}

### Markers record the checksum of the script that satisfied the step. If the script is later
### edited, the checksum no longer matches and the step runs again - which is what makes
### re-running the installer after a change do the right thing.
marker_for()  { printf '%s/%s.done' "$STATE_DIR" "$1"; }
script_hash() { sha256sum "$1" | cut -d' ' -f1; }

step_state() {
  local name="$1" path="$STEP_DIR/$1" marker
  marker="$(marker_for "$name")"
  [ -f "$path" ]   || { echo "missing"; return; }
  [ -f "$marker" ] || { echo "pending"; return; }
  if [ "$(cat "$marker")" = "$(script_hash "$path")" ]; then echo "done"; else echo "changed"; fi
}

### ----------------------------------------------------------------------------------------
### --list
### ----------------------------------------------------------------------------------------

if [ "$DO_LIST" -eq 1 ]; then
  printf '\n%sInstall plan%s  (steps in %s, roles: %s%s%s)\n\n' \
    "$C_BOLD" "$C_RESET" "$STEP_DIR" "$C_BOLD" "$ROLES" "$C_RESET"
  for entry in "${STEPS[@]}"; do
    name="$(step_name "$entry")"
    roles="$(step_roles "$entry")"

    if ! step_applies "$roles"; then
      printf '  %bskipped%b      %-26s %s\n' \
        "$C_YELLOW" "$C_RESET" "$name" "not a '$ROLES' role (needs: $roles)"
      continue
    fi

    case "$(step_state "$name")" in
      done)    tag="${C_GREEN}done${C_RESET}      " ;;
      changed) tag="${C_YELLOW}changed${C_RESET}   " ;;
      pending) tag="${C_BLUE}pending${C_RESET}   " ;;
      missing) tag="${C_RED}not written${C_RESET}" ;;
    esac
    printf '  %b  %-26s %s\n' "$tag" "$name" "$(step_desc "$entry")"
  done
  printf '\n'
  exit 0
fi

### ----------------------------------------------------------------------------------------
### Execution
### ----------------------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "Run this with sudo."

mkdir -p "$LOG_DIR" "$STATE_DIR" "$STEP_DIR"
LOG_FILE="$LOG_DIR/install-$(date '+%Y%m%d-%H%M%S').log"

### Everything from here on is teed to the log, so a step's own output is captured too.
exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_STEP="startup"

### Any non-zero exit - including one from set -e inside a step - reports which step broke
### and where to read the log, rather than leaving a bare stack-free failure.
# shellcheck disable=SC2329 # invoked indirectly by the EXIT trap below
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "Failed during: $CURRENT_STEP (exit $rc)"
    fail "Log: $LOG_FILE"
  fi
  exit "$rc"
}
trap on_exit EXIT

info "VoIP PBX installer starting"
info "Logging to $LOG_FILE"
[ "$DO_DRYRUN" -eq 1 ] && warn "DRY RUN - no step will actually execute"

info "Roles on this machine: $ROLES"

started=0
ran=0; skipped=0; absent=0; notmyrole=0

for entry in "${STEPS[@]}"; do
  name="$(step_name "$entry")"
  desc="$(step_desc "$entry")"
  roles="$(step_roles "$entry")"
  path="$STEP_DIR/$name"

  ### --only runs exactly one step; --from starts the run at a given step.
  if [ -n "$ONLY_STEP" ] && [ "$name" != "$ONLY_STEP" ]; then continue; fi
  if [ -n "$FROM_STEP" ] && [ "$started" -eq 0 ]; then
    if [ "$name" = "$FROM_STEP" ]; then started=1; else continue; fi
  fi

  ### --only is an explicit instruction, so it overrides role filtering: an operator asking
  ### for one step by name should get it rather than a silent skip.
  if [ -z "$ONLY_STEP" ] && ! step_applies "$roles"; then
    notmyrole=$((notmyrole + 1))
    continue
  fi

  state="$(step_state "$name")"

  if [ "$state" = "missing" ]; then
    warn "SKIP  $name - not written yet ($desc)"
    absent=$((absent + 1))
    continue
  fi

  if [ "$DO_FORCE" -eq 0 ] && [ "$state" = "done" ]; then
    info "SKIP  $name - already completed"
    skipped=$((skipped + 1))
    continue
  fi

  [ "$state" = "changed" ] && info "$name changed since last run - re-running"

  if [ "$DO_DRYRUN" -eq 1 ]; then
    info "WOULD RUN  $name - $desc"
    continue
  fi

  CURRENT_STEP="$name"
  info "RUN   $name - $desc"
  start_ts=$(date +%s)

  chmod +x "$path"
  ### A failing step aborts the run: set -e plus the EXIT trap report which one broke.
  "$path"

  printf '%s' "$(script_hash "$path")" > "$(marker_for "$name")"
  ok "$name completed in $(( $(date +%s) - start_ts ))s"
  ran=$((ran + 1))
done

if [ -n "$ONLY_STEP" ] && [ "$ran" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$absent" -eq 0 ]; then
  die "No such step: $ONLY_STEP (try --list)"
fi

CURRENT_STEP="finish"
printf '\n'
ok "Done. $ran run, $skipped already complete, $absent not yet written, $notmyrole not for this role."
info "Log: $LOG_FILE"
[ "$absent" -gt 0 ] && warn "The install is incomplete until the missing steps above exist."
exit 0
