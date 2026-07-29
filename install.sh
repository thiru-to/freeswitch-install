#!/usr/bin/env bash
set -euo pipefail

FS_VERSION="${1:-v1.11.1}"
BUILD_DIR="/usr/src"
PREFIX="/usr/local/freeswitch"
JOBS="$(nproc)"

sudo apt -y update
sudo apt -y upgrade
sudo apt -y install htop curl git sngrep ca-certificates \
  gpg vim-tiny tcpdump rsyslog apt-transport-https gnupg2 lsb-release wget

### Freeswitch dependencies
sudo apt -y install \
  git build-essential automake autoconf wget libtool \
  libncurses-dev libjpeg-dev libsqlite3-dev libcurl4-openssl-dev \
  libpcre2-dev libspeexdsp-dev libspeex-dev libldns-dev libedit-dev \
  libssl-dev zlib1g-dev liblua5.2-dev libopus-dev libsndfile1-dev \
  libavformat-dev libswscale-dev libtool-bin libtiff-dev cmake uuid-dev \
  libpq-dev libshout3-dev libmp3lame-dev libmpg123-dev \
  libhiredis-dev libmemcached-dev

### Clone repositories.
cd "$BUILD_DIR"
[ -d "$BUILD_DIR/libks" ]      || sudo git clone https://github.com/signalwire/libks.git
[ -d "$BUILD_DIR/spandsp" ]    || sudo git clone https://github.com/freeswitch/spandsp.git
[ -d "$BUILD_DIR/freeswitch" ] || sudo git clone -b "$FS_VERSION" https://github.com/signalwire/freeswitch.git
[ -d "$BUILD_DIR/sofia-sip" ]  || sudo git clone https://github.com/freeswitch/sofia-sip.git

### resources/ (the systemd unit template) comes from this repo. Refresh it on re-runs so a
### stale clone from an earlier install does not deploy an out-of-date unit file.
if [ -d "$BUILD_DIR/freeswitch-install" ]; then
  sudo git -C "$BUILD_DIR/freeswitch-install" pull --ff-only
else
  sudo git clone https://github.com/thiru-to/freeswitch-install.git
fi

### Install spandsp
cd "$BUILD_DIR/spandsp"

sudo ./bootstrap.sh
sudo ./configure
sudo make -j"$JOBS"
sudo make install

### Install libks
cd "$BUILD_DIR/libks"
sudo cmake .
sudo make -j"$JOBS"
sudo make install

### Install sofia-sip
cd "$BUILD_DIR/sofia-sip"
sudo ./bootstrap.sh
sudo ./configure --enable-debug
sudo make -j"$JOBS"
sudo make install

sudo ldconfig

### Install freeswitch
cd "$BUILD_DIR/freeswitch"
sudo ./bootstrap.sh -j

### Modules to build, over and above the stock modules.conf selection. The path prefixes must
### match build/modules.conf.in exactly or the sed silently does nothing, so each edit is
### verified below.
FS_ENABLE_MODULES="
applications/mod_callcenter
applications/mod_cidlookup
applications/mod_memcache
applications/mod_hiredis
applications/mod_curl
applications/mod_easyroute
applications/mod_nibblebill
event_handlers/mod_fail2ban
formats/mod_shout
databases/mod_pgsql
xml_int/mod_xml_curl
"

FS_DISABLE_MODULES="
applications/mod_signalwire
applications/mod_av
endpoints/mod_skinny
endpoints/mod_verto
say/mod_say_es
say/mod_say_fr
xml_int/mod_xml_rpc
"

for m in $FS_ENABLE_MODULES; do
  if ! grep -qE "^#?${m}\$" modules.conf; then
    echo "ERROR: '$m' not found in modules.conf - the module path changed upstream" >&2
    exit 1
  fi
  sudo sed -i "s|^#${m}\$|${m}|" modules.conf
done

for m in $FS_DISABLE_MODULES; do
  if ! grep -qE "^#?${m}\$" modules.conf; then
    echo "ERROR: '$m' not found in modules.conf - the module path changed upstream" >&2
    exit 1
  fi
  sudo sed -i "s|^${m}\$|#${m}|" modules.conf
done

sudo ./configure -C \
  --disable-dependency-tracking --enable-debug --enable-core-pgsql-support

sudo make -j"$JOBS"
sudo make install

### Install freeswitch sounds
sudo make sounds-install moh-install
sudo make cd-sounds-install cd-moh-install

### Replace the stock vanilla config with the minimal one. 'make install' only lays down a
### config when $PREFIX/conf is absent, and 'config-minimal' will not overwrite existing
### files, so the old tree has to go first.
sudo rm -rf "$PREFIX/conf"
sudo make config-minimal

if [ ! -f "$PREFIX/conf/freeswitch.xml" ]; then
  echo "ERROR: $PREFIX/conf/freeswitch.xml is missing - 'make config-minimal' did not complete" >&2
  exit 1
fi

### Create freeswitch group & user and give permissions.
getent group freeswitch >/dev/null || sudo groupadd freeswitch
id -u freeswitch >/dev/null 2>&1 || sudo adduser --quiet --system  \
  --gecos 'FreeSWITCH open source softswitch' --ingroup freeswitch --disabled-password freeswitch

FS_ADMINS="${SUDO_USER:-${USER:-}}"
for admin_group in sudo admin; do
  members="$(getent group "$admin_group" | cut -d: -f4 | tr ',' ' ')" || members=""
  FS_ADMINS="$FS_ADMINS $members"
done
### The invoking user is usually also a member of the sudo group - dedupe so we do not
### call usermod twice for them.
FS_ADMINS="$(echo "$FS_ADMINS" | tr ' ' '\n' | sort -u)"

# shellcheck disable=SC2086 # word splitting is intentional here
for u in $FS_ADMINS; do
  if [ "$u" = "root" ] || ! id -u "$u" >/dev/null 2>&1; then
    continue
  fi
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx freeswitch; then
    continue
  fi
  sudo usermod -aG freeswitch "$u"
  echo "Added '$u' to the freeswitch group"
done

sudo ln -sf "$PREFIX/bin/fs_cli" /usr/bin/fs_cli
sudo ln -sf "$PREFIX/bin/freeswitch" /usr/sbin/freeswitch

### FreeSWITCH runs as the freeswitch user and writes to db/, log/, run/ and recordings/
### underneath the prefix, so the whole tree has to be owned by it.
sudo chown -R freeswitch:freeswitch "$PREFIX"
sudo chmod -R u+rwX,g+rwX,o-rwx "$PREFIX/conf" "$PREFIX/db" "$PREFIX/log"

### Conventional location for the config, for anyone who goes looking in /etc.
sudo ln -sfn "$PREFIX/conf" /etc/freeswitch

if [ ! -x "$PREFIX/bin/freeswitch" ]; then
  echo "ERROR: $PREFIX/bin/freeswitch is missing - 'make install' did not complete" >&2
  exit 1
fi

### Create freeswitch service
sudo sed "s|\${PREFIX}|$PREFIX|g" "$BUILD_DIR/freeswitch-install/resources/freeswitch.service" \
  | sudo tee /etc/systemd/system/freeswitch.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable freeswitch.service
sudo systemctl start freeswitch.service

echo
echo "FreeSWITCH $FS_VERSION installed to $PREFIX."
echo "  status : sudo systemctl status freeswitch"
echo "  console: fs_cli"
echo "  config : $PREFIX/conf (also linked as /etc/freeswitch)"
echo
echo "Members of the freeswitch group must log out and back in for it to take effect."
