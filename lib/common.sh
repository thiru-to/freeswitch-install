#!/usr/bin/env bash
#
# Shared helpers for the step scripts. Source this, do not execute it:
#
#   STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$STEP_DIR/../lib/common.sh"
#
# Everything here is written to be safe to run repeatedly. Helpers that change the system
# report what they changed and stay quiet when there is nothing to do, so a second run of the
# installer produces a log that is almost entirely "already correct".

# shellcheck shell=bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/voip-pbx"
CONFIG_FILE="$CONFIG_DIR/config.env"

### --- Output ---------------------------------------------------------------------------

if [ -t 1 ]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'
else
  _C_RESET=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""
fi

info() { printf '  %s->%s %s\n'  "$_C_BLUE"   "$_C_RESET" "$*"; }
ok()   { printf '  %s ok%s %s\n' "$_C_GREEN"  "$_C_RESET" "$*"; }
warn() { printf '  %s !!%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*"; }
fail() { printf '  %s XX%s %s\n' "$_C_RED"    "$_C_RESET" "$*" >&2; }
die()  { fail "$*"; exit 1; }

### --- Guards ---------------------------------------------------------------------------

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This must run as root (use sudo)."
}

require_debian() {
  [ -f /etc/os-release ] || die "Cannot identify the OS - /etc/os-release is missing."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "Unsupported OS '${ID:-unknown}'. This installer targets Debian/Ubuntu." ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

### --- Configuration --------------------------------------------------------------------

# Generates a URL-safe secret. Used for values that end up in config files and connection
# strings, so the alphabet avoids characters that need quoting or escaping.
#
# Reads a BOUNDED block rather than the obvious `tr -dc … < /dev/urandom | head -c N`. In that
# form head closes the pipe once it has N bytes, tr is killed by SIGPIPE and exits 141, and
# `set -o pipefail` turns that into a failed install. Worse, whether it happens at all depends
# on pipe buffering, so it fails intermittently. Here head bounds the input and exits cleanly,
# tr reads to EOF, and no process is ever signalled.
random_secret() {
  local len="${1:-32}" out=""
  while [ "${#out}" -lt "$len" ]; do
    # 8x oversample: the alphabet keeps roughly 3/4 of random bytes, so one pass almost always
    # suffices and the loop is a guard rather than the normal path.
    out="${out}$(LC_ALL=C head -c "$((len * 8))" /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:len}"
}

# Writes KEY="value" back into the deployed config, replacing any existing entry. This is how
# generated secrets persist between runs.
config_set() {
  local key="$1" value="$2"
  touch "$CONFIG_FILE"
  if grep -qE "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

# Ensures a secret exists, generating it on first use. Re-running never rotates a secret -
# that would break every service already holding the old one.
config_ensure_secret() {
  local key="$1" len="${2:-32}" current=""
  current="$(eval "printf '%s' \"\${$key:-}\"")"
  if [ -z "$current" ]; then
    current="$(random_secret "$len")"
    config_set "$key" "$current"
    export "$key=$current"
    info "Generated $key"
  fi
}

load_config() {
  ### 0755, not 0750. Service users need to traverse this directory to reach material we
  ### deliberately share with them - /etc/voip-pbx/tls, group-readable by ssl-cert. With 0750
  ### root:root the group permission on the files below is unreachable, and Kamailio fails to
  ### start with an opaque "Permission denied" from OpenSSL. The secret is config.env itself,
  ### which is 0600 and stays that way.
  if [ ! -d "$CONFIG_DIR" ]; then
    install -d -m 0755 "$CONFIG_DIR"
  else
    chmod 0755 "$CONFIG_DIR"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    install -m 0600 "$REPO_DIR/config.env.example" "$CONFIG_FILE"
    warn "Created $CONFIG_FILE from the template."
    warn "Edit it now - PBX_FQDN, LETSENCRYPT_EMAIL and ADMIN_ALLOW_CIDR must be real."
    die "Re-run once $CONFIG_FILE is filled in."
  fi
  chmod 0600 "$CONFIG_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a

  [ "${PBX_FQDN:-}" != "pbx.example.com" ] || die "PBX_FQDN is still the placeholder in $CONFIG_FILE."
  [ -n "${PBX_FQDN:-}" ] || die "PBX_FQDN is not set in $CONFIG_FILE."
}

### --- Roles ----------------------------------------------------------------------------

### True when this machine plays the given role. Steps use this for conditional work inside a
### step - for example opening a firewall port only on the machine that actually binds it.
### An all-in-one host ("all") plays every role.
has_role() {
  local want="$1" r
  case " ${ROLES:-all} " in *" all "*) return 0 ;; esac
  for r in ${ROLES:-all}; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

### True when every component shares one host, i.e. all inter-component traffic is loopback.
### Used to decide whether a service should bind loopback only or an internal address.
is_all_in_one() {
  case " ${ROLES:-all} " in *" all "*) return 0 ;; esac
  return 1
}

### The address a service should bind for internal traffic. Loopback on an all-in-one box;
### the host's internal address once roles are split, so peers can actually reach it.
internal_bind_addr() {
  if is_all_in_one; then
    printf '127.0.0.1'
  else
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || printf '0.0.0.0'
  fi
}

### --- Packages -------------------------------------------------------------------------

APT_UPDATED=0

apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
  fi
}

# Installs only what is actually missing, so a re-run is near-instant and the log stays clean.
apt_install() {
  local missing=()
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "Packages already present: $*"
    return 0
  fi
  apt_update_once
  info "Installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold "${missing[@]}"
}

# Adds a third-party apt repository using a dearmoured keyring under /usr/share/keyrings.
# Signed-by keeps the key scoped to this one repo rather than trusting it globally.
apt_add_repo() {
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/usr/share/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"

  apt_install curl gnupg ca-certificates

  if [ ! -s "$keyring" ]; then
    info "Fetching signing key for $name"
    curl -fsSL "$key_url" | gpg --dearmor -o "$keyring"
    chmod 0644 "$keyring"
    APT_UPDATED=0
  fi

  local desired="deb [signed-by=${keyring}] ${repo_line}"
  if [ ! -f "$list" ] || [ "$(cat "$list")" != "$desired" ]; then
    printf '%s\n' "$desired" > "$list"
    APT_UPDATED=0
    info "Configured apt repository: $name"
  else
    ok "apt repository already configured: $name"
  fi
}

### --- Files ----------------------------------------------------------------------------

# Writes stdin to a path only if the content differs. Returns 0 when changed, 1 when it was
# already correct - which lets a caller decide whether a service needs reloading.
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root:root}"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  install -d -m 0755 "$(dirname "$path")"

  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    chmod "$mode" "$path"; chown "$owner" "$path"
    ok "Already current: $path"
    return 1
  fi

  # Keep one backup of whatever we are replacing - useful when a config change breaks a
  # service and you need to see what it looked like before.
  if [ -f "$path" ]; then
    cp -a "$path" "${path}.bak-$(date +%Y%m%d%H%M%S)"
  fi

  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  info "Wrote $path"
  return 0
}

# Ensures a single directive exists in a config file, replacing any existing (even commented)
# occurrence. Used for sshd_config and similar key/value files.
ensure_directive() {
  local file="$1" key="$2" value="$3" sep="${4:- }"
  touch "$file"
  if grep -qE "^[#[:space:]]*${key}${sep}" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}${sep}.*|${key}${sep}${value}|" "$file"
  else
    printf '%s%s%s\n' "$key" "$sep" "$value" >> "$file"
  fi
}

### --- Services -------------------------------------------------------------------------

enable_service() {
  local unit="$1"
  systemctl enable --now "$unit" >/dev/null 2>&1 || systemctl enable --now "$unit"
  if systemctl is-active --quiet "$unit"; then
    ok "$unit is active"
  else
    systemctl status "$unit" --no-pager -l | head -20 >&2 || true
    die "$unit failed to start"
  fi
}

restart_service() {
  local unit="$1"
  info "Restarting $unit"
  systemctl restart "$unit"
  sleep 1
  systemctl is-active --quiet "$unit" || {
    systemctl status "$unit" --no-pager -l | head -20 >&2 || true
    die "$unit failed to restart"
  }
  ok "$unit restarted"
}

### --- Postgres helper ------------------------------------------------------------------

psql_super() { su - postgres -c "psql -v ON_ERROR_STOP=1 $*"; }

pg_role_exists() {
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$1'\"" | grep -q 1
}

pg_db_exists() {
  su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$1'\"" | grep -q 1
}
