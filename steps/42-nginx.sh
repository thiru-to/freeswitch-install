#!/usr/bin/env bash
### nginx: TLS termination for the API and the ACME webroot for renewals.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install nginx

TLS_DIR="/etc/voip-pbx/tls"
if [ ! -f "$TLS_DIR/fullchain.pem" ]; then
  die "No certificate at $TLS_DIR - run 13-tls-certs.sh first."
fi
usermod -aG ssl-cert www-data 2>/dev/null || true

### ACME renewals switch from standalone to webroot now that nginx owns :80, so certbot never
### needs to stop the web server to renew.
install -d -m 0755 /var/www/acme
write_file /etc/letsencrypt/cli.ini 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
authenticator = webroot
webroot-path = /var/www/acme
EOF

rm -f /etc/nginx/sites-enabled/default

write_file /etc/nginx/conf.d/00-hardening.conf 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
server_tokens off;

# TLS policy, applied to every server block.
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;

# Rate limit zones. Applied per-location below; login endpoints get the strict one.
limit_req_zone $binary_remote_addr zone=api_general:10m rate=20r/s;
limit_req_zone $binary_remote_addr zone=api_auth:10m rate=5r/m;
EOF

write_file /etc/nginx/sites-available/voip-api 0644 <<EOF || true
# Managed by the VoIP PBX installer.

server {
    listen 80;
    listen [::]:80;
    server_name ${PBX_FQDN};

    # ACME validation must stay reachable over plain HTTP for renewals.
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${PBX_FQDN};

    ssl_certificate     ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key ${TLS_DIR}/privkey.pem;

    # HSTS. Only safe because everything here is served over TLS.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Do not let a large body tie up the API.
    client_max_body_size 10m;
    client_body_timeout 30s;

    access_log /var/log/nginx/voip-api.access.log;
    error_log  /var/log/nginx/voip-api.error.log warn;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    # Authentication endpoints are the ones worth brute forcing, so they are limited far
    # more tightly than ordinary API traffic.
    location ~ ^/(auth|login|token) {
        limit_req zone=api_auth burst=5 nodelay;
        proxy_pass http://127.0.0.1:${API_PORT};
        include /etc/nginx/proxy_params;
    }

    location / {
        limit_req zone=api_general burst=40 nodelay;
        proxy_pass http://127.0.0.1:${API_PORT};
        include /etc/nginx/proxy_params;
    }
}
EOF

### Debian ships proxy_params, but not with WebSocket upgrade handling - which SIP over WSS
### and any realtime API endpoint both need.
write_file /etc/nginx/proxy_params 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 300s;
proxy_send_timeout 300s;
EOF

### $connection_upgrade must be defined at http scope for the above to work.
write_file /etc/nginx/conf.d/01-upgrade-map.conf 0644 <<'EOF' || true
# Managed by the VoIP PBX installer.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

ln -sf /etc/nginx/sites-available/voip-api /etc/nginx/sites-enabled/voip-api

nginx -t || die "nginx configuration is invalid."
enable_service nginx
restart_service nginx

ok "nginx serving https://${PBX_FQDN}/ -> 127.0.0.1:${API_PORT}"
