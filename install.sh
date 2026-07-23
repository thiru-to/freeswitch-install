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
  libpq-dev libshout3-dev libmp3lame-dev libmpg123-dev nasm yasm \
  libhiredis-dev libmemcached-dev

### Clone repositories.
cd "$BUILD_DIR"
[ -d "$BUILD_DIR/libks" ]      || sudo git clone https://github.com/signalwire/libks.git
[ -d "$BUILD_DIR/spandsp" ]    || sudo git clone https://github.com/freeswitch/spandsp.git
[ -d "$BUILD_DIR/freeswitch" ] || sudo git clone -b "$FS_VERSION" https://github.com/signalwire/freeswitch.git
[ -d "$BUILD_DIR/sofia-sip" ]  || sudo git clone https://github.com/freeswitch/sofia-sip.git
[ -d "$BUILD_DIR/freeswitch-install" ] || sudo git clone https://github.com/thiru-to/freeswitch-install.git

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

### Enable modules
sudo sed -i 's|^#applications/mod_callcenter|applications/mod_callcenter|' modules.conf
sudo sed -i 's|^#applications/mod_cidlookup|applications/mod_cidlookup|' modules.conf
sudo sed -i 's|^#applications/mod_memcache|applications/mod_memcache|' modules.conf
sudo sed -i 's|^#applications/mod_hiredis|applications/mod_hiredis|' modules.conf
sudo sed -i 's|^#applications/mod_curl|applications/mod_curl|' modules.conf
sudo sed -i 's|^#applications/mod_easyroute|applications/mod_easyroute|' modules.conf
sudo sed -i 's|^#applications/mod_nibblebill|applications/mod_nibblebill|' modules.conf
sudo sed -i 's|^#event_handlers/mod_fail2ban|event_handlers/mod_fail2ban|' modules.conf
sudo sed -i 's|^#formats/mod_shout|formats/mod_shout|' modules.conf
sudo sed -i 's|^#formats/mod_pgsql|formats/mod_pgsql|' modules.conf
sudo sed -i 's|^#xml_int/mod_xml_curl|xml_int/mod_xml_curl|' modules.conf

### Disable modules
sudo sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|' modules.conf
sudo sed -i 's|^endpoints/mod_skinny|#endpoints/mod_skinny|' modules.conf
sudo sed -i 's|^endpoints/mod_verto|#endpoints/mod_verto|' modules.conf
sudo sed -i 's|^applications/mod_say_es|#applications/mod_say_es|' modules.conf
sudo sed -i 's|^applications/mod_say_fr|#applications/mod_say_fr|' modules.conf
sudo sed -i 's|^applications/mod_av|#applications/mod_av|' modules.conf
sudo sed -i 's|^xml_int/mod_xml_rpc|#xml_int/mod_xml_rpc|' modules.conf

sudo ./configure -C --prefix="$PREFIX" \
  --disable-dependency-tracking --enable-debug --enable-core-pgsql-support --with-openssl

sudo make -j"$JOBS"
sudo make install

### Install freeswitch sounds
sudo make sounds-install moh-install
sudo make cd-sounds-install cd-moh-install

### Create freeswitch group & user and give permissions.
getent group freeswitch >/dev/null || sudo groupadd freeswitch
id -u freeswitch >/dev/null 2>&1 || sudo adduser --quiet --system --home "$PREFIX" \
  --gecos 'FreeSWITCH open source softswitch' --ingroup freeswitch --disabled-password freeswitch
if [ ! -x "$PREFIX/bin/freeswitch" ]; then
  echo "ERROR: $PREFIX/bin/freeswitch is missing - 'make install' did not complete" >&2
  exit 1
fi

sudo chown -R freeswitch:freeswitch "$PREFIX"

### Lock everything down to the service account first.
sudo chmod -R ug=rwX,o= "$PREFIX"

### Then reopen the read-only parts. Binaries, libraries, modules and sounds must stay
### readable/executable by ordinary users so fs_cli works without sudo; conf/, db/, log/,
### run/, certs/, recordings/ and storage/ stay owner+group only.
###
### Pass DIRECTORIES here, never a glob: a glob is expanded by the unprivileged calling
### shell, which can no longer read $PREFIX after the chmod above, and the unexpanded
### pattern is then handed to chmod verbatim.
sudo chmod o=rX "$PREFIX"
for d in bin lib mod share; do
  if [ -d "$PREFIX/$d" ]; then
    sudo chmod -R u=rwX,g=rX,o=rX "$PREFIX/$d"
  fi
done

sudo ln -sf "$PREFIX/bin/freeswitch" /usr/local/bin/freeswitch
sudo ln -sf "$PREFIX/bin/fs_cli"     /usr/local/bin/fs_cli

### Create freeswitch service
sudo sed "s|\${PREFIX}|$PREFIX|g" "$BUILD_DIR/freeswitch-install/resources/freeswitch.service" \
  | sudo tee /etc/systemd/system/freeswitch.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now freeswitch
