#!/usr/bin/env bash
### SSH hardening. Refuses to lock you out: password auth is only disabled once at least one
### authorised key actually exists.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

CONF=/etc/ssh/sshd_config.d/90-hardening.conf
install -d -m 0755 /etc/ssh/sshd_config.d

### --- Key check ------------------------------------------------------------------------

### Disabling password auth on a host where nobody has uploaded a key is how you lose access
### to a production box. Count keys for every non-system account plus root first.
key_count=0
while IFS=: read -r user _ uid _ _ home _; do
  [ "$uid" -ge 1000 ] || [ "$user" = "root" ] || continue
  [ -f "$home/.ssh/authorized_keys" ] || continue
  n="$(grep -cvE '^\s*(#|$)' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
  if [ "$n" -gt 0 ]; then
    info "$user has $n authorised key(s)"
    key_count=$((key_count + n))
  fi
done < /etc/passwd

DISABLE_PASSWORDS=1
if [ "$key_count" -eq 0 ]; then
  warn "No authorised SSH keys found anywhere on this host."
  warn "Leaving password authentication ENABLED so you are not locked out."
  warn "Add a key, then re-run: sudo ./install.sh --only 10-ssh-hardening.sh --force"
  DISABLE_PASSWORDS=0
fi

### --- Config --------------------------------------------------------------------------

{
  echo "# Managed by the VoIP PBX installer."
  echo "PermitRootLogin no"
  echo "PubkeyAuthentication yes"
  if [ "$DISABLE_PASSWORDS" -eq 1 ]; then
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
  else
    echo "PasswordAuthentication yes"
    echo "KbdInteractiveAuthentication yes"
  fi
  echo "PermitEmptyPasswords no"
  echo "X11Forwarding no"
  echo "AllowAgentForwarding no"
  echo "MaxAuthTries 3"
  echo "MaxSessions 10"
  echo "LoginGraceTime 30"
  echo "ClientAliveInterval 300"
  echo "ClientAliveCountMax 2"
  echo "# Modern algorithms only."
  echo "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512"
  echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
  echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
} | write_file "$CONF" 0644 || true

### Drop weak Diffie-Hellman moduli. Cheap, and removes a whole class of downgrade attack.
if [ -f /etc/ssh/moduli ] && awk '$5 < 3071' /etc/ssh/moduli | grep -q .; then
  awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.strong
  mv /etc/ssh/moduli.strong /etc/ssh/moduli
  info "Removed weak DH moduli"
fi

sshd -t || die "sshd configuration is invalid - not restarting. Fix $CONF first."
systemctl reload ssh 2>/dev/null || systemctl reload sshd
ok "SSH hardened (password auth $([ "$DISABLE_PASSWORDS" -eq 1 ] && echo disabled || echo "left enabled"))"
