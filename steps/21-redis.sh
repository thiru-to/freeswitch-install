#!/usr/bin/env bash
### Redis, used by FreeSWITCH via mod_hiredis and by the API for caching.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

apt_install redis-server

config_ensure_secret REDIS_PASSWORD 40

write_file /etc/redis/redis.conf.d/90-voip.conf 0640 redis:redis <<EOF || true
# Managed by the VoIP PBX installer.

# Loopback only. Nothing outside this host has any business talking to Redis.
bind 127.0.0.1 -::1
protected-mode yes
port 6379

requirepass ${REDIS_PASSWORD}

# Cache and short-lived state, not a system of record - Postgres holds anything durable.
# Evict the least recently used keys rather than returning errors when memory runs out.
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence off: everything here is reconstructible, and fsync pauses would show up as
# latency on call setup.
save ""
appendonly no

# Rename the commands that can wipe or reconfigure the instance out from under the services.
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
EOF

### Debian's redis.conf does not include a conf.d directory by default.
if ! grep -q "^include /etc/redis/redis.conf.d/" /etc/redis/redis.conf; then
  install -d -m 0750 -o redis -g redis /etc/redis/redis.conf.d
  printf '\n# Added by the VoIP PBX installer.\ninclude /etc/redis/redis.conf.d/*.conf\n' \
    >> /etc/redis/redis.conf
  info "Enabled /etc/redis/redis.conf.d includes"
fi

enable_service redis-server
restart_service redis-server

if redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
  ok "Redis responding on 127.0.0.1:6379 (password protected)"
else
  die "Redis is not responding to an authenticated PING."
fi
