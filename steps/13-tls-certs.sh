#!/usr/bin/env bash
### Let's Encrypt certificate plus renewal hooks. One certificate serves nginx (API/WSS),
### Kamailio (SIP TLS) and FreeSWITCH.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install certbot

LIVE="/etc/letsencrypt/live/$PBX_FQDN"

### --- Issue -----------------------------------------------------------------------------

if [ -d "$LIVE" ]; then
  ok "Certificate already exists for $PBX_FQDN"
else
  staging_flag=""
  [ "${LETSENCRYPT_STAGING:-0}" = "1" ] && staging_flag="--staging" && \
    warn "Using the Let's Encrypt STAGING CA - the certificate will not be publicly trusted."

  ### standalone binds :80 itself. nginx is not installed yet at this point in the run, so
  ### there is nothing to conflict with; later renewals use the webroot hook below.
  info "Requesting a certificate for $PBX_FQDN"
  # shellcheck disable=SC2086
  certbot certonly --standalone --non-interactive --agree-tos \
    --email "$LETSENCRYPT_EMAIL" -d "$PBX_FQDN" \
    --key-type ecdsa --preferred-challenges http $staging_flag \
    || die "Certificate issuance failed. Check that $PBX_FQDN resolves here and :80 is reachable."
  ok "Certificate issued"
fi

### --- Shared copy for the telephony services ---------------------------------------------

### Kamailio and FreeSWITCH do not run as root and must not read /etc/letsencrypt directly.
### Copy the material into a group-readable location instead, and refresh it on renewal.
getent group ssl-cert >/dev/null || groupadd --system ssl-cert
install -d -m 0750 -o root -g ssl-cert /etc/voip-pbx/tls

write_file /usr/local/sbin/voip-deploy-certs 0755 <<EOF || true
#!/usr/bin/env bash
# Managed by the VoIP PBX installer. Run by certbot after every successful renewal.
set -euo pipefail
FQDN="$PBX_FQDN"
SRC="/etc/letsencrypt/live/\$FQDN"
DST="/etc/voip-pbx/tls"

[ -d "\$SRC" ] || exit 0

install -m 0644 -o root -g ssl-cert "\$SRC/fullchain.pem" "\$DST/fullchain.pem"
install -m 0640 -o root -g ssl-cert "\$SRC/privkey.pem"   "\$DST/privkey.pem"

# Kamailio wants certificate and key in one file for some TLS configurations.
cat "\$SRC/fullchain.pem" "\$SRC/privkey.pem" > "\$DST/combined.pem.tmp"
install -m 0640 -o root -g ssl-cert "\$DST/combined.pem.tmp" "\$DST/combined.pem"
rm -f "\$DST/combined.pem.tmp"

# Reload rather than restart wherever possible: a restart drops calls in progress.
systemctl reload nginx     2>/dev/null || true
systemctl is-active --quiet kamailio   && systemctl reload kamailio   2>/dev/null || true
systemctl is-active --quiet freeswitch && /usr/local/freeswitch/bin/fs_cli -x "reloadxml" >/dev/null 2>&1 || true

logger -t voip-deploy-certs "Deployed renewed certificate for \$FQDN"
EOF

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
ln -sf /usr/local/sbin/voip-deploy-certs /etc/letsencrypt/renewal-hooks/deploy/voip-deploy-certs

/usr/local/sbin/voip-deploy-certs
ok "Certificate material published to /etc/voip-pbx/tls (group ssl-cert)"

### --- Renewal ---------------------------------------------------------------------------

### certbot ships a systemd timer; make sure it is actually on. Renewal that silently stops
### working is a classic way to take a PBX offline 90 days after install.
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
  ok "Automatic renewal enabled ($(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo 'timer active'))"
else
  warn "certbot.timer is not enabled - renewals will not happen automatically."
fi

certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date" | sed 's/^/  /' || true
ok "TLS certificates configured"
