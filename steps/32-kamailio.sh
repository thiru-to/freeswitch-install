#!/usr/bin/env bash
### Kamailio from deb.kamailio.org - the public-facing SIP proxy and registrar.
###
### Debian ships Kamailio in main, but a major version behind (6.0.x on trixie). The upstream
### repo is used so the version is a deliberate choice rather than whatever the distro froze.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

KAMAILIO_REPO_VERSION="${KAMAILIO_REPO_VERSION:-kamailio61}"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

apt_add_repo "kamailio" \
  "http://deb.kamailio.org/kamailiodebkey.gpg" \
  "http://deb.kamailio.org/${KAMAILIO_REPO_VERSION} ${codename} main"

### Each package here maps to modules kamailio.cfg actually loads. Missing one is not a
### warning - Kamailio refuses to parse a config referencing a module it cannot find, so the
### whole proxy fails to start.
apt_install \
  kamailio \
  kamailio-postgres-modules \
  kamailio-tls-modules \
  kamailio-lua-modules \
  kamailio-utils-modules \
  kamailio-presence-modules \
  kamailio-json-modules \
  kamailio-extra-modules \
  kamailio-websocket-modules   # websocket.so + xhttp.so, required for SIP over WSS (WebRTC)

### Stop the stock config from starting before 33-kamailio-config.sh has written a real one.
### The shipped default is a bare example that would briefly open a misconfigured proxy on
### the public SIP port.
systemctl stop kamailio 2>/dev/null || true
systemctl disable kamailio >/dev/null 2>&1 || true

installed="$(dpkg-query -W -f='${Version}' kamailio 2>/dev/null || echo unknown)"
ok "Kamailio ${installed} installed (left stopped - 33-kamailio-config.sh configures and starts it)"
