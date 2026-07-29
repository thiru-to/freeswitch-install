#!/usr/bin/env bash
### Roles and databases for Kamailio and the API. Least privilege: neither role owns or can
### reach the other's data, and neither is a superuser.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

command -v psql >/dev/null || die "PostgreSQL is not installed - run 20-postgresql.sh first."
systemctl is-active --quiet postgresql || die "PostgreSQL is not running."

config_ensure_secret KAMAILIO_DB_PASSWORD 32
config_ensure_secret KAMAILIO_RO_DB_PASSWORD 32
config_ensure_secret API_DB_PASSWORD 32

### --- Roles -----------------------------------------------------------------------------

### Kamailio conventionally uses two accounts: a read/write one for the registrar tables it
### maintains, and a read-only one used by the config at routing time. If the SIP-facing
### config is ever exploited, the read-only credentials cannot modify subscribers.
create_role() {
  local role="$1" password="$2"
  if pg_role_exists "$role"; then
    ok "Role already exists: $role"
  else
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE \\\"${role}\\\" LOGIN PASSWORD '${password}'\"" >/dev/null
    info "Created role: $role"
  fi
  ### Re-apply the password every run so the database always matches config.env - otherwise
  ### a restored config and a live database can silently drift apart.
  su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE \\\"${role}\\\" WITH LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE\"" >/dev/null
}

create_db() {
  local db="$1" owner="$2"
  if pg_db_exists "$db"; then
    ok "Database already exists: $db"
  else
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE \\\"${db}\\\" OWNER \\\"${owner}\\\" ENCODING 'UTF8'\"" >/dev/null
    info "Created database: $db (owner $owner)"
  fi
}

create_role "kamailio"    "$KAMAILIO_DB_PASSWORD"
create_role "kamailioro"  "$KAMAILIO_RO_DB_PASSWORD"
create_role "$API_USER"   "$API_DB_PASSWORD"

create_db "kamailio" "kamailio"
create_db "voipapi"  "$API_USER"

### --- Privileges ------------------------------------------------------------------------

### Revoke the implicit PUBLIC grant. Without this every role on the cluster can connect to
### and create objects in every database, which defeats the separation above.
for db in kamailio voipapi; do
  su - postgres -c "psql -v ON_ERROR_STOP=1 -d ${db} -c \"REVOKE ALL ON SCHEMA public FROM PUBLIC\"" >/dev/null
  su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"REVOKE ALL ON DATABASE \\\"${db}\\\" FROM PUBLIC\"" >/dev/null
done

su - postgres -c "psql -v ON_ERROR_STOP=1 -d kamailio -c \"GRANT ALL ON SCHEMA public TO kamailio\"" >/dev/null
su - postgres -c "psql -v ON_ERROR_STOP=1 -d voipapi  -c \"GRANT ALL ON SCHEMA public TO \\\"${API_USER}\\\"\"" >/dev/null

### The read-only role gets SELECT on everything Kamailio creates, now and in future - the
### DEFAULT PRIVILEGES clause covers tables that 33-kamailio-config.sh has not made yet.
su - postgres -c "psql -v ON_ERROR_STOP=1 -d kamailio -c \"GRANT CONNECT ON DATABASE kamailio TO kamailioro\"" >/dev/null
su - postgres -c "psql -v ON_ERROR_STOP=1 -d kamailio -c \"GRANT USAGE ON SCHEMA public TO kamailioro\"" >/dev/null
su - postgres -c "psql -v ON_ERROR_STOP=1 -d kamailio -c \"GRANT SELECT ON ALL TABLES IN SCHEMA public TO kamailioro\"" >/dev/null
su - postgres -c "psql -v ON_ERROR_STOP=1 -d kamailio -c \"ALTER DEFAULT PRIVILEGES FOR ROLE kamailio IN SCHEMA public GRANT SELECT ON TABLES TO kamailioro\"" >/dev/null

### --- Verify ----------------------------------------------------------------------------

check_login() {
  local role="$1" pass="$2" db="$3"
  if PGPASSWORD="$pass" psql -h 127.0.0.1 -U "$role" -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
    ok "Login verified: ${role}@${db}"
  else
    die "Cannot log in as ${role} to ${db} - check pg_hba.conf."
  fi
}

check_login kamailio   "$KAMAILIO_DB_PASSWORD"    kamailio
check_login kamailioro "$KAMAILIO_RO_DB_PASSWORD" kamailio
check_login "$API_USER" "$API_DB_PASSWORD"        voipapi

ok "Databases provisioned"
