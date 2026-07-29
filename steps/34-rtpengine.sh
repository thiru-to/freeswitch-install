#!/usr/bin/env bash
### rtpengine - the media relay.
###
### Not optional for this deployment. Clients are on WiFi and mobile behind NAT, and with
### Kamailio proxying signalling the two endpoints cannot generally reach each other
### directly. Without a relay the usual symptom is a call that connects with no audio, or
### audio in one direction only.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

### Debian 13 carries rtpengine in main, so no third-party repo or source build is needed.
apt_install rtpengine-daemon rtpengine-utils

### --- Kernel forwarding module ------------------------------------------------------------

### Userspace forwarding works but costs a context switch per packet. The kernel module moves
### established flows into netfilter, which is the difference between a few hundred and a few
### thousand concurrent calls on the same hardware. It is best-effort: a missing DKMS build
### must not fail the install.
KERNEL_TABLE=0
if apt_install rtpengine-kernel-dkms 2>/dev/null && modprobe xt_RTPENGINE 2>/dev/null; then
  KERNEL_TABLE=1
  ok "Kernel forwarding module loaded"
  write_file /etc/modules-load.d/rtpengine.conf 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
xt_RTPENGINE
EOF
else
  warn "xt_RTPENGINE unavailable - falling back to userspace forwarding."
  warn "That is functionally correct but uses noticeably more CPU per call."
fi

### --- Configuration -------------------------------------------------------------------------

### Bind the control socket to loopback: it is an unauthenticated control channel, and
### Kamailio is the only thing that should ever speak to it.
local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[ -n "$local_ip" ] || die "Could not determine this host's primary IPv4 address."

### On a cloud instance the interface holds a private address while SIP advertises the public
### one. rtpengine needs both so it can advertise the right address in SDP.
public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
if [ -n "$public_ip" ] && [ "$public_ip" != "$local_ip" ]; then
  interface_spec="${local_ip}!${public_ip}"
  info "NAT detected: advertising ${public_ip}, bound to ${local_ip}"
else
  interface_spec="${local_ip}"
fi

write_file /etc/rtpengine/rtpengine.conf 0644 <<EOF || true
# Managed by the VoIP PBX installer.
[rtpengine]
interface = ${interface_spec}

# Control channel for Kamailio's rtpengine module. Loopback only.
listen-ng = 127.0.0.1:${RTPENGINE_NG_PORT}

port-min = ${RTP_PORT_MIN}
port-max = ${RTP_PORT_MAX}

$( [ "$KERNEL_TABLE" = "1" ] && echo "table = 0" || echo "table = -1" )

# Hang up media for calls whose signalling vanished, so ports are not leaked forever.
timeout = 60
silent-timeout = 3600
final-timeout = 21600

# Delete delay of 0 frees ports immediately on BYE rather than holding them.
delete-delay = 0

log-level = 5
log-stderr = false

# Do not fall over if a single stream misbehaves.
graphite =
num-threads = $(nproc)
EOF

### The Debian unit reads defaults from here.
ensure_directive /etc/default/rtpengine "RUN_RTPENGINE" "yes" "="

enable_service rtpengine
restart_service rtpengine

sleep 2
if ss -lun 2>/dev/null | grep -q ":${RTPENGINE_NG_PORT}"; then
  ok "rtpengine control socket listening on 127.0.0.1:${RTPENGINE_NG_PORT}"
else
  warn "rtpengine does not appear to be listening on ${RTPENGINE_NG_PORT} - check: journalctl -u rtpengine"
fi

ok "rtpengine ready (media ${RTP_PORT_MIN}-${RTP_PORT_MAX}, $( [ "$KERNEL_TABLE" = "1" ] && echo "kernel" || echo "userspace" ) forwarding)"
