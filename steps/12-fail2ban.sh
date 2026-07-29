#!/usr/bin/env bash
### fail2ban jails for SSH and SIP. SIP brute force is constant and automated on any public
### IP - this is not optional hardening.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install fail2ban

### Use nftables as the ban backend so bans land in the same ruleset as 11-firewall.sh
### rather than fighting it with a parallel iptables chain.
write_file /etc/fail2ban/jail.d/00-defaults.local <<'EOF' || true
# Managed by the VoIP PBX installer.
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
backend = systemd
findtime = 10m
bantime = 1h
maxretry = 5

# Escalating bans: repeat offenders get progressively longer time-outs, which is far more
# effective against botnets that cycle slowly than a fixed ban.
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d
EOF

write_file /etc/fail2ban/jail.d/sshd.local <<'EOF' || true
# Managed by the VoIP PBX installer.
[sshd]
enabled = true
mode = aggressive
maxretry = 3
bantime = 2h
EOF

### FreeSWITCH ships mod_fail2ban (we build it), which writes auth failures to the FreeSWITCH
### log in a format fail2ban can parse.
write_file /etc/fail2ban/filter.d/freeswitch-pbx.conf <<'EOF' || true
# Managed by the VoIP PBX installer.
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*\[WARNING\].*SOFIA.*Wrong password.*from ip <HOST>.*$
            ^.*\[WARNING\].*SOFIA.*Can't find user.*from ip <HOST>.*$
            ^.*\[WARNING\].*SOFIA.*Register.*Auth Failure.*from ip <HOST>.*$
            ^.*\[WARNING\].*mod_fail2ban.*<HOST>.*$
ignoreregex =
journalmatch = _SYSTEMD_UNIT=freeswitch.service
EOF

write_file /etc/fail2ban/jail.d/freeswitch.local <<'EOF' || true
# Managed by the VoIP PBX installer.
[freeswitch-pbx]
enabled  = true
filter   = freeswitch-pbx
port     = 5060,5061,5080
protocol = all
logpath  = /usr/local/freeswitch/log/freeswitch.log
backend  = auto
maxretry = 5
findtime = 10m
bantime  = 6h
EOF

### Kamailio is the public-facing SIP element, so it sees the scans first. It logs auth
### failures to syslog under its own unit.
write_file /etc/fail2ban/filter.d/kamailio-auth.conf <<'EOF' || true
# Managed by the VoIP PBX installer.
[Definition]
failregex = ^.*Auth error.*from <HOST>.*$
            ^.*authentication failed.*<HOST>.*$
            ^.*sanity check failed.*<HOST>.*$
ignoreregex =
journalmatch = _SYSTEMD_UNIT=kamailio.service
EOF

write_file /etc/fail2ban/jail.d/kamailio.local <<'EOF' || true
# Managed by the VoIP PBX installer.
[kamailio-auth]
enabled  = true
filter   = kamailio-auth
port     = 5060,5061
protocol = all
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 6h
EOF

### The FreeSWITCH jail points at a log file that only exists after 30-freeswitch.sh has run.
### Tolerate its absence so the security tier can be applied to a fresh host first.
if [ ! -f /usr/local/freeswitch/log/freeswitch.log ]; then
  warn "FreeSWITCH log not present yet - its jail starts working after 30-freeswitch.sh."
  install -d -m 0755 /usr/local/freeswitch/log
  touch /usr/local/freeswitch/log/freeswitch.log
fi

fail2ban-client -t >/dev/null || die "fail2ban configuration is invalid."
enable_service fail2ban
restart_service fail2ban

info "Active jails: $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | xargs)"
ok "fail2ban configured"
