#!/usr/bin/env bash
### Deploy the Hono API: dependencies, Drizzle migrations, systemd unit.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

SRC="$REPO_DIR/app/api"
[ -d "$SRC" ] || die "No API source at $SRC."
command -v bun >/dev/null || die "Bun is not installed - run 40-bun.sh first."

### --- Service account ----------------------------------------------------------------------

### A dedicated unprivileged account with no login shell. The API talks to Postgres and
### FreeSWITCH's ESL; it has no reason to be able to log in.
if ! id -u "$API_USER" >/dev/null 2>&1; then
  adduser --system --group --home "$API_DIR" --shell /usr/sbin/nologin \
    --gecos "VoIP PBX API" "$API_USER"
  info "Created service account: $API_USER"
fi

### --- Code ---------------------------------------------------------------------------------

install -d -m 0750 -o "$API_USER" -g "$API_USER" "$API_DIR"

### node_modules is rebuilt from the lockfile on the target, so excluding it keeps the copy
### fast and avoids shipping a macOS-built esbuild binary to a Linux server.
rsync -a --delete \
  --exclude 'node_modules' --exclude '.env' --exclude '.git' \
  "$SRC/" "$API_DIR/"
chown -R "$API_USER:$API_USER" "$API_DIR"
ok "Source synced to $API_DIR"

### --- Environment ----------------------------------------------------------------------------

### Secrets live in a root-owned file the service can read but not modify, rather than being
### baked into the unit where they would show up in `systemctl show`.
write_file "$API_DIR/.env" 0640 "root:$API_USER" <<EOF || true
# Managed by the VoIP PBX installer. Regenerated on every deploy - do not hand-edit.
NODE_ENV=production
PORT=${API_PORT}
HOST=127.0.0.1

DATABASE_URL=postgres://${API_USER}:${API_DB_PASSWORD}@127.0.0.1:5432/voipapi

REDIS_URL=redis://:${REDIS_PASSWORD:-}@127.0.0.1:6379

FS_ESL_HOST=127.0.0.1
FS_ESL_PORT=8021
FS_ESL_PASSWORD=${FS_ESL_PASSWORD}

PBX_FQDN=${PBX_FQDN}
PBX_SIP_DOMAIN=${PBX_SIP_DOMAIN}
EOF

### --- Dependencies and migrations ---------------------------------------------------------

info "Installing dependencies"
su -s /bin/bash -c "cd '$API_DIR' && bun install --frozen-lockfile --production" "$API_USER" \
  || su -s /bin/bash -c "cd '$API_DIR' && bun install" "$API_USER" \
  || die "bun install failed."

if grep -q '"drizzle-kit"' "$API_DIR/package.json" 2>/dev/null && [ -f "$API_DIR/drizzle.config.ts" ]; then
  info "Applying database migrations"
  ### Migrations are the one step that can leave the database half-changed, so a failure here
  ### stops the deploy rather than starting an API against a schema it does not match.
  su -s /bin/bash -c "cd '$API_DIR' && bunx drizzle-kit push --force" "$API_USER" \
    || die "Database migration failed - not starting the API against a mismatched schema."
  ok "Migrations applied"
fi

### --- Service --------------------------------------------------------------------------------

### Determine the entrypoint: package.json start script wins, else a conventional filename.
ENTRY="server.ts"
for candidate in server.ts src/index.ts index.ts; do
  [ -f "$API_DIR/$candidate" ] && ENTRY="$candidate" && break
done
info "Entrypoint: $ENTRY"

write_file /etc/systemd/system/voip-api.service 0644 <<EOF || true
[Unit]
# Managed by the VoIP PBX installer.
Description=VoIP PBX API
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=${API_USER}
Group=${API_USER}
WorkingDirectory=${API_DIR}
EnvironmentFile=${API_DIR}/.env
ExecStart=/usr/local/bin/bun run ${ENTRY}
Restart=on-failure
RestartSec=5

# Bind to loopback only - nginx terminates TLS and proxies in.
# Hardening: the API needs the network and its own directory, nothing else.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
ReadWritePaths=${API_DIR}

StandardOutput=journal
StandardError=journal
SyslogIdentifier=voip-api

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
enable_service voip-api
restart_service voip-api

sleep 3
if ss -ltn 2>/dev/null | grep -q ":${API_PORT}"; then
  ok "API listening on 127.0.0.1:${API_PORT}"
else
  warn "Nothing listening on ${API_PORT} yet - check: journalctl -u voip-api -n 50"
fi

ok "API deployed"
