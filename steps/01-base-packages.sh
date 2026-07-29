#!/usr/bin/env bash
### Common tooling and automatic security updates.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install \
  curl wget git ca-certificates gnupg lsb-release apt-transport-https \
  vim-tiny htop jq rsync \
  tcpdump sngrep ngrep \
  rsyslog logrotate \
  unattended-upgrades apt-listchanges

### --- Unattended security upgrades ------------------------------------------------------

### Security patches only. Deliberately not enabling the general updates origin: an unplanned
### restart of Kamailio or FreeSWITCH drops every call in progress, so anything beyond
### security fixes should be a decision you make during a maintenance window.
write_file /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF' || true
// Managed by the VoIP PBX installer.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
        // Never restart telephony out from under live calls automatically.
        "freeswitch";
        "kamailio";
        "rtpengine";
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || true
// Managed by the VoIP PBX installer.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
ok "Unattended security upgrades enabled (telephony packages held back)"

ok "Base packages complete"
