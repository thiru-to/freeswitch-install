#!/usr/bin/env bash
### PostgreSQL from the PGDG repository, tuned for this workload.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

PG_VERSION="${PG_VERSION:-18}"

### --- Repository -------------------------------------------------------------------------

### Debian ships an older major version; PGDG is the upstream apt repo and carries current
### releases for the same codename.
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
apt_add_repo "pgdg" \
  "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
  "https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main"

apt_install "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" postgresql-common

CLUSTER_DIR="/etc/postgresql/${PG_VERSION}/main"
[ -d "$CLUSTER_DIR" ] || die "Expected cluster config at $CLUSTER_DIR - is postgresql-${PG_VERSION} installed?"

### --- Tuning ----------------------------------------------------------------------------

### Bind loopback on an all-in-one box; add the internal address once roles are split, so the
### sip/media/portal nodes can actually reach the database.
if is_all_in_one; then
  pg_listen="localhost"
else
  pg_listen="localhost,$(internal_bind_addr)"
fi

### Sized from actual host memory rather than fixed numbers, so this behaves on both a small
### VM and a large one. Conservative general-purpose values; a busy CDR workload may want
### more work_mem, which is why this lives in its own drop-in you can edit.
mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
shared_buffers=$(( mem_mb / 4 ))
effective_cache=$(( mem_mb / 2 ))
maint_work_mem=$(( mem_mb / 16 ))
[ "$maint_work_mem" -gt 2048 ] && maint_work_mem=2048
[ "$shared_buffers" -lt 128 ] && shared_buffers=128

install -d -m 0755 -o postgres -g postgres "${CLUSTER_DIR}/conf.d"

write_file "${CLUSTER_DIR}/conf.d/90-voip.conf" 0644 postgres:postgres <<EOF || true
# Managed by the VoIP PBX installer. Sized for a host with ${mem_mb}MB RAM.

listen_addresses = '${pg_listen}'
max_connections = 200

shared_buffers = ${shared_buffers}MB
effective_cache_size = ${effective_cache}MB
maintenance_work_mem = ${maint_work_mem}MB
work_mem = 8MB

# SSD defaults: random reads cost roughly the same as sequential ones.
random_page_cost = 1.1
effective_io_concurrency = 200

# Write-ahead logging sized to allow point-in-time recovery and future replication.
wal_level = replica
max_wal_size = 2GB
min_wal_size = 512MB
checkpoint_completion_target = 0.9

# Log slow queries and every DDL change - invaluable when a call flow suddenly gets slow.
log_min_duration_statement = 500
log_line_prefix = '%m [%p] %q%u@%d '
log_checkpoints = on
log_statement = 'ddl'
log_autovacuum_min_duration = 0

# CDR tables grow monotonically; keep autovacuum keen so they do not bloat.
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

timezone = '${TIMEZONE}'
EOF

### --- Access ----------------------------------------------------------------------------

### scram-sha-256 for local TCP; peer for the postgres superuser over the unix socket.
### Off-host access exists only once roles are split - on an all-in-one box the internal
### line is deliberately absent rather than a permissive no-op.
if is_all_in_one; then
  pg_hba_internal="# (all-in-one: no off-host access)"
else
  pg_hba_internal="host    all             all             ${INTERNAL_CIDR}            scram-sha-256"
fi

write_file "${CLUSTER_DIR}/pg_hba.conf" 0640 postgres:postgres <<EOF || true
# Managed by the VoIP PBX installer.
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
${pg_hba_internal}
EOF

systemctl enable postgresql >/dev/null 2>&1 || true
if systemctl list-unit-files | grep -q "postgresql@${PG_VERSION}-main"; then
  restart_service "postgresql@${PG_VERSION}-main"
else
  restart_service postgresql
fi

### The postgres superuser has no password by default - it authenticates by peer over the unix
### socket. That is fine for us, but tools that connect over TCP need one: kamdbctl builds a
### psql command with -h and then fails on a missing ~/.pgpass. Set it once and persist it.
config_ensure_secret PG_SUPERUSER_PASSWORD 32
su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE postgres WITH PASSWORD '${PG_SUPERUSER_PASSWORD}'\"" >/dev/null
ok "Superuser password set (for TCP admin tools such as kamdbctl)"

su - postgres -c "psql -tAc 'SELECT version()'" | sed 's/^/  /'
ok "PostgreSQL ${PG_VERSION} ready (listening on ${pg_listen}, shared_buffers=${shared_buffers}MB)"
