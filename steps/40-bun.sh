#!/usr/bin/env bash
### Bun runtime, installed system-wide.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

BUN_INSTALL="/usr/local/lib/bun"
BUN_BIN="/usr/local/bin/bun"

### Bun's installer is a shell script from bun.sh. Pin BUN_INSTALL so it lands in a system
### location rather than root's home, which is where it would otherwise go and would then be
### invisible to the service user.
if [ -x "$BUN_BIN" ]; then
  ok "Bun already installed: $("$BUN_BIN" --version)"
else
  apt_install unzip curl
  info "Installing Bun"
  install -d -m 0755 "$BUN_INSTALL"
  BUN_INSTALL="$BUN_INSTALL" bash -c "$(curl -fsSL https://bun.sh/install)" >/dev/null \
    || die "Bun installation failed."
  ln -sf "$BUN_INSTALL/bin/bun" "$BUN_BIN"
  ln -sf "$BUN_INSTALL/bin/bun" /usr/local/bin/bunx
  ok "Bun $("$BUN_BIN" --version) installed to $BUN_INSTALL"
fi

### Make it available to non-login shells and systemd units without each needing PATH tweaks.
write_file /etc/profile.d/bun.sh 0644 <<EOF || true
# Managed by the VoIP PBX installer.
export BUN_INSTALL="${BUN_INSTALL}"
case ":\$PATH:" in
  *":\$BUN_INSTALL/bin:"*) ;;
  *) export PATH="\$BUN_INSTALL/bin:\$PATH" ;;
esac
EOF

"$BUN_BIN" --version >/dev/null || die "Bun is installed but not runnable."
ok "Bun ready"
