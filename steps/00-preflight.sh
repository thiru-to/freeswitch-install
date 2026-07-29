#!/usr/bin/env bash
### Host validation and baseline tuning. Everything else assumes this ran.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
require_debian
load_config

### --- Sanity ---------------------------------------------------------------------------

# shellcheck disable=SC1091
. /etc/os-release
info "Host: ${PRETTY_NAME:-unknown} on $(uname -m), $(nproc) CPUs, $(awk '/MemTotal/{printf "%.1fGB", $2/1048576}' /proc/meminfo)"

case "$(uname -m)" in
  x86_64|aarch64) : ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

### A media server that cannot keep up will drop audio long before it runs out of disk.
### These are floors, not recommendations.
mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
[ "$mem_mb" -ge 1800 ] || warn "Only ${mem_mb}MB RAM - 2GB is a realistic minimum for this stack."
disk_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "$disk_gb" -ge 15 ] || warn "Only ${disk_gb}GB free on / - the FreeSWITCH build plus sounds needs ~10GB."

### --- DNS ------------------------------------------------------------------------------

### Let's Encrypt validates over HTTP against this name, so a wrong record fails the TLS step
### much later and more confusingly. Catch it here.
resolved="$(getent ahostsv4 "$PBX_FQDN" 2>/dev/null | awk 'NR==1{print $1}')" || resolved=""
if [ -z "$resolved" ]; then
  warn "$PBX_FQDN does not resolve. Let's Encrypt (13-tls-certs.sh) will fail until it does."
else
  public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
  if [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
    warn "$PBX_FQDN resolves to $resolved but this host's public IP looks like $public_ip."
    warn "Certificate issuance will fail unless that is a proxy or the DNS is still propagating."
  else
    ok "$PBX_FQDN resolves to $resolved"
  fi
fi

### --- Identity -------------------------------------------------------------------------

if [ "$(hostnamectl --static 2>/dev/null)" != "$PBX_FQDN" ]; then
  hostnamectl set-hostname "$PBX_FQDN"
  info "Hostname set to $PBX_FQDN"
fi

# Keep the FQDN resolvable locally so services that look up their own name do not stall.
short="${PBX_FQDN%%.*}"
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${PBX_FQDN}" /etc/hosts; then
  sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
  printf '127.0.1.1\t%s %s\n' "$PBX_FQDN" "$short" >> /etc/hosts
  info "Added $PBX_FQDN to /etc/hosts"
fi

timedatectl set-timezone "$TIMEZONE"
ok "Timezone: $TIMEZONE"

### --- Time -----------------------------------------------------------------------------

### Clock drift corrupts CDR timestamps and breaks TLS certificate validation outright.
apt_install chrony
enable_service chrony

### --- Kernel and limits ----------------------------------------------------------------

### Defaults are tuned for a handful of TCP streams, not thousands of small UDP packets
### arriving every 20ms. Undersized socket buffers show up as crackling audio under load.
write_file /etc/sysctl.d/90-voip.conf <<EOF || true
# Managed by the VoIP PBX installer.

# Larger socket buffers: RTP is many small packets, and the default 208KB is easily
# overrun by a few hundred concurrent calls.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 5000

# Connection tracking sized for SIP registrations plus RTP flows.
net.netfilter.nf_conntrack_max = 262144

# SIP over UDP does not benefit from these, and they slow down failover.
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300

# Allow services to bind ports before the address is fully up (failover, restarts).
net.ipv4.ip_nonlocal_bind = 1

# Do not let the box swap out a media process - jitter is worse than memory pressure.
vm.swappiness = 10
EOF
sysctl --system >/dev/null
ok "Kernel parameters applied"

### FreeSWITCH and Kamailio both open a lot of descriptors: one per registration, per call
### leg, per database handle. The 1024 default is exhausted almost immediately.
write_file /etc/security/limits.d/90-voip.conf <<'EOF' || true
# Managed by the VoIP PBX installer.
*       soft    nofile  100000
*       hard    nofile  100000
*       soft    nproc   60000
*       hard    nproc   60000
root    soft    nofile  100000
root    hard    nofile  100000
EOF
ok "File descriptor limits raised"

### --- Base OS updates ------------------------------------------------------------------

apt_update_once
info "Applying pending security updates"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confold

ok "Preflight complete"
