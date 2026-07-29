#!/usr/bin/env bash

# Install Postgresql 18 for Debian.
# sudo apt install -y curl ca-certificates
# sudo install -d /usr/share/postgresql-common/pgdg
# sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc

# /etc/apt/sources.list.d/pgdg.sources
#

# echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.sources

#
#Types: deb deb-src
# URIs: https://apt.postgresql.org/pub/repos/apt
# Suites: trixie-pgdg
# Architectures: amd64
# Components: main
# Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

# sudo apt update
# sudo apt install postgresql-18
# sudo systemctl enable postgresql
# sudo systemctl start postgresql
# sudo systemctl status postgresql