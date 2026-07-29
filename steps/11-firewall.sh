#!/usr/bin/env bash
### nftables: default deny inbound, with an allowlist for SIP, RTP, HTTPS and admin access.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install nftables

### Build the admin allowlist. Anything not in here cannot reach SSH.
admin_set=""
for cidr in $ADMIN_ALLOW_CIDR; do
  admin_set="${admin_set}${admin_set:+, }${cidr}"
done
[ -n "$admin_set" ] || die "ADMIN_ALLOW_CIDR is empty in $CONFIG_FILE."
if [ "$ADMIN_ALLOW_CIDR" = "0.0.0.0/0" ]; then
  warn "ADMIN_ALLOW_CIDR is 0.0.0.0/0 - SSH is exposed to the whole internet."
  warn "Narrow this to your office/VPN range in $CONFIG_FILE."
fi

write_file /etc/nftables.conf 0644 <<EOF || true
#!/usr/sbin/nft -f
# Managed by the VoIP PBX installer. Regenerate with: install.sh --only 11-firewall.sh --force
flush ruleset

table inet filter {
    # Hosts that tripped the SIP rate limit. fail2ban adds longer-term bans separately.
    set sip_flood {
        type ipv4_addr
        flags dynamic, timeout
        timeout 10m
    }

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        # ICMP is needed for path MTU discovery - dropping it breaks large SIP packets
        # over TCP in ways that are miserable to debug.
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # Admin access.
        ip saddr { ${admin_set} } tcp dport 22 accept

        # ACME HTTP-01 validation and the API behind nginx.
        tcp dport { 80, 443 } accept

        # SIP. The rate limit blunts registration floods and scanner sweeps before they
        # reach Kamailio's own auth handling.
        udp dport ${SIP_PORT} add @sip_flood { ip saddr limit rate over 40/second } drop
        udp dport ${SIP_PORT} accept
        tcp dport ${SIP_PORT} accept
        tcp dport ${SIPS_PORT} accept
$( [ "${ENABLE_WEBRTC:-1}" = "1" ] && printf '        # SIP over secure WebSocket, for browser clients.\n        tcp dport %s accept' "${WSS_PORT:-8443}" )

        # RTP media, handled by rtpengine.
        udp dport ${RTP_PORT_MIN}-${RTP_PORT_MAX} accept

        # Anything else that reached this point is dropped by policy. Log a sample so the
        # rule set can be debugged without drowning the journal.
        limit rate 5/minute log prefix "nft-drop: " level info
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

nft -c -f /etc/nftables.conf || die "nftables ruleset is invalid - not applying."

### enable AND start. Enabling alone leaves the unit inactive until the next boot, so the
### ruleset is live (we load it below) while systemd reports the firewall as not running -
### which is exactly the kind of discrepancy that makes someone distrust the monitoring.
systemctl enable --now nftables >/dev/null 2>&1 || systemctl enable nftables >/dev/null 2>&1 || true
nft -f /etc/nftables.conf
ok "Firewall active: SSH limited to ${ADMIN_ALLOW_CIDR}, SIP ${SIP_PORT}/${SIPS_PORT}, RTP ${RTP_PORT_MIN}-${RTP_PORT_MAX}"
