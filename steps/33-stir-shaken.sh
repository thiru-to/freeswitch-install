#!/usr/bin/env bash
### STIR/SHAKEN - caller ID attestation for outbound PSTN calls.
###
### Regulatory background: the FCC (US) and CRTC (Canada) require originating carriers to
### sign outbound calls with a PASSporT attesting to how well they know the caller. Calls
### that arrive unsigned or with a low attestation increasingly get labelled "Scam Likely" by
### terminating carriers, so this is as much a deliverability concern as a compliance one.
###
### This step is a source build. Neither libstirshaken nor Kamailio's stirshaken module is
### packaged for Debian - the module has an upstream package group, but Debian cannot build
### it without the library. dSIPRouter carries a patch for the same reason.
###
### Disabled by default: signing also requires a certificate issued by an STI-CA authorised
### by the policy administrator, which is a procurement exercise, not an install step.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

if [ "${ENABLE_STIR_SHAKEN:-0}" != "1" ]; then
  info "ENABLE_STIR_SHAKEN is not 1 - skipping."
  info "Set it in $CONFIG_FILE once you hold an STI-CA certificate, then re-run this step."
  exit 0
fi

BUILD_DIR="/usr/src"
command -v kamailio >/dev/null || die "Kamailio is not installed - run 32-kamailio.sh first."

MPATH="$(dirname "$(find /usr/lib -name 'tm.so' -path '*kamailio*' 2>/dev/null | head -1)")"
[ -n "$MPATH" ] || die "Could not locate the Kamailio module directory."

### --- Dependencies --------------------------------------------------------------------------

### libjwt 1.17 in Debian satisfies libstirshaken's ">= 1.12" and is still the 1.x API. The
### upstream README points at SignalWire's token-gated repo; Debian's package avoids that.
apt_install build-essential automake autoconf libtool pkg-config \
  libcurl4-openssl-dev libssl-dev libjwt-dev uuid-dev

### libks is already built from source by 30-freeswitch.sh. Reuse it rather than pulling in
### SignalWire's repository for a second copy.
if [ ! -f /usr/local/lib/pkgconfig/libks2.pc ] && [ ! -f /usr/lib/pkgconfig/libks2.pc ]; then
  if [ -d "$BUILD_DIR/libks" ]; then
    info "Building libks (from the FreeSWITCH source tree)"
    ( cd "$BUILD_DIR/libks" && cmake . >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
    ldconfig
  else
    die "libks not found. Run 30-freeswitch.sh first, or install libks manually."
  fi
fi
ok "libks present"

### --- libstirshaken -------------------------------------------------------------------------

if [ -f /usr/local/lib/libstirshaken.so ] || [ -f /usr/lib/libstirshaken.so ]; then
  ok "libstirshaken already installed"
else
  [ -d "$BUILD_DIR/libstirshaken" ] || \
    git clone https://github.com/signalwire/libstirshaken.git "$BUILD_DIR/libstirshaken"

  info "Building libstirshaken (a few minutes)"
  (
    cd "$BUILD_DIR/libstirshaken"
    ./bootstrap.sh >/dev/null
    ./configure >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
  ) || die "libstirshaken build failed. Build it by hand in $BUILD_DIR/libstirshaken to see why."
  ldconfig
  ok "libstirshaken built and installed"
fi

### --- Kamailio stirshaken module ------------------------------------------------------------

if [ -f "$MPATH/stirshaken.so" ]; then
  ok "Kamailio stirshaken module already present"
else
  ### The module must be built from the *same* Kamailio version as the installed packages, or
  ### it will fail to load against a mismatched internal ABI.
  kam_ver="$(kamailio -v 2>/dev/null | awk '/^version:/{print $3}')"
  [ -n "$kam_ver" ] || die "Could not determine the installed Kamailio version."
  info "Building the stirshaken module for Kamailio $kam_ver"

  SRC="$BUILD_DIR/kamailio-$kam_ver"
  if [ ! -d "$SRC" ]; then
    git clone --depth 1 -b "$kam_ver" https://github.com/kamailio/kamailio.git "$SRC" 2>/dev/null \
      || git clone --depth 1 -b "${kam_ver%.*}" https://github.com/kamailio/kamailio.git "$SRC" \
      || die "Could not fetch Kamailio source matching $kam_ver."
  fi

  (
    cd "$SRC"
    make cfg >/dev/null 2>&1 || true
    make modules modules=src/modules/stirshaken >/dev/null
  ) || die "stirshaken module build failed. Build it by hand in $SRC to see why."

  built="$(find "$SRC/src/modules/stirshaken" -name 'stirshaken.so' | head -1)"
  [ -n "$built" ] || die "Build reported success but produced no stirshaken.so."
  install -m 0644 "$built" "$MPATH/stirshaken.so"
  ok "Installed stirshaken.so into $MPATH"
fi

### --- Certificate material ---------------------------------------------------------------------

### Signing key and certificate come from an STI-CA. The certificate must be published at a
### public HTTPS URL (the x5u), because verifying carriers fetch it to check the signature.
install -d -m 0750 -o root -g kamailio /etc/voip-pbx/stir

SS_KEY="${STIR_SHAKEN_KEY:-/etc/voip-pbx/stir/signing.key}"
SS_CERT="${STIR_SHAKEN_CERT:-/etc/voip-pbx/stir/signing.pem}"

if [ ! -f "$SS_KEY" ] || [ ! -f "$SS_CERT" ]; then
  warn "No signing material at $SS_KEY / $SS_CERT."
  warn "Obtain an SP certificate from an STI-CA (you need an OCN and an SPC token from"
  warn "the policy administrator), then place the EC private key and certificate there."
  warn "Publish the certificate at STIR_SHAKEN_X5U so verifiers can fetch it."
  warn "Kamailio will VERIFY inbound calls but will not SIGN outbound ones until then."
  SIGNING_READY=0
else
  chown root:kamailio "$SS_KEY" "$SS_CERT"
  chmod 0640 "$SS_KEY"; chmod 0644 "$SS_CERT"
  ### An RS256 key here is a common mistake - the SHAKEN profile mandates ES256 on P-256.
  if ! openssl ec -in "$SS_KEY" -noout 2>/dev/null; then
    warn "$SS_KEY is not an EC key. SHAKEN requires ES256 (prime256v1) - signing will fail."
  fi
  SIGNING_READY=1
  ok "Signing material present"
fi

### The CA bundle used to validate inbound PASSporTs. Populated with the STI-CA roots you
### trust; falling back to the system store is deliberately not done, because any public CA
### would then be able to vouch for a caller identity.
CA_DIR="/etc/voip-pbx/stir/ca"
install -d -m 0755 "$CA_DIR"
if [ -z "$(ls -A "$CA_DIR" 2>/dev/null)" ]; then
  warn "No STI-CA root certificates in $CA_DIR - inbound verification will reject everything."
  warn "Add the roots you trust (from the STI-PA trust list) as .pem files there."
fi

write_file /etc/voip-pbx/stir/README 0644 <<EOF || true
STIR/SHAKEN material for ${PBX_FQDN}.

  signing.key   EC (prime256v1) private key issued with your SP certificate. Mode 0640.
  signing.pem   The SP certificate itself, published publicly at:
                ${STIR_SHAKEN_X5U:-<set STIR_SHAKEN_X5U in /etc/voip-pbx/config.env>}
  ca/           STI-CA root certificates you trust for verifying inbound calls.

Attestation levels sent on outbound calls (STIR_SHAKEN_ATTEST):
  A  You authenticated the caller AND they are authorised to use that number.
  B  You authenticated the caller but cannot confirm the number is theirs.
  C  The call entered your network from elsewhere; you can only identify the gateway.

Claiming A for traffic you cannot actually vouch for is a compliance problem, not a
configuration shortcut.
EOF

### --- Kamailio configuration fragment ---------------------------------------------------------

### Written as a separate file that 34-kamailio-config.sh imports, so the routing logic can
### live alongside the feature rather than being conditionally spliced into the main config.
write_file /etc/kamailio/stirshaken.cfg 0640 root:kamailio <<EOF || true
# Managed by the VoIP PBX installer. Imported by kamailio.cfg.

loadmodule "stirshaken.so"

modparam("stirshaken", "vs_verify_x509_cert_path", 1)
modparam("stirshaken", "vs_ca_dir", "${CA_DIR}")
modparam("stirshaken", "vs_cache_certificates", 1)
modparam("stirshaken", "vs_cache_expire_s", 3600)
# Reject a PASSporT whose iat is far from now - this is the replay defence.
modparam("stirshaken", "vs_identity_expire_s", 60)
modparam("stirshaken", "vs_connect_timeout_s", 3)

$( [ "$SIGNING_READY" = "1" ] && cat <<INNER
modparam("stirshaken", "as_default_key", "${SS_KEY}")
INNER
)
EOF

systemctl is-active --quiet kamailio && restart_service kamailio || true

ok "STIR/SHAKEN ready (verification on$( [ "$SIGNING_READY" = "1" ] && echo ", signing on" || echo ", signing pending a certificate" ))"
info "Re-run 34-kamailio-config.sh so the routing logic picks this up:"
info "  sudo ./install.sh --only 34-kamailio-config.sh --force"
