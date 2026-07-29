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
  libhiredis-dev

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

### Install freeswitch sounds, one rate at a time. Do NOT use the hd-/uhd-/cd- convenience
### targets: they chain downwards (cd- depends on uhd- depends on hd- depends on 8k), so
### 'cd-sounds-install' quietly drags down all four rates (~383MB). The per-rate targets below
### go through the Makefile's .DEFAULT rule and fetch exactly one tarball each.
### 8000 covers G.711/PSTN legs, 48000 covers Opus. Add 16000/32000 here if you ever need them.
FS_SOUND_RATES="8000 48000"
for rate in $FS_SOUND_RATES; do
  sudo make "sounds-en-us-callie-${rate}-install" "sounds-music-${rate}-install"
done

### Replace the stock vanilla config with the minimal one. 'make install' only lays down a
### config when $PREFIX/conf is absent, and 'config-minimal' will not overwrite existing
### files, so the old tree has to go first.
sudo rm -rf "$PREFIX/conf"
sudo make config-minimal

if [ ! -f "$PREFIX/conf/freeswitch.xml" ]; then
  echo "ERROR: $PREFIX/conf/freeswitch.xml is missing - 'make config-minimal' did not complete" >&2
  exit 1
fi

### The stock minimal config autoloads mod_xml_rpc, which we deliberately do not build.
### Left alone it logs a [CRIT] on every start. Comment out any autoloaded module that
### was not built so a disabled module never turns into boot noise.
FS_AUTOLOAD_CONF="$PREFIX/conf/autoload_configs/modules.conf.xml"
for m in $FS_DISABLE_MODULES; do
  mod_name="${m##*/}"
  grep -q "<load module=\"${mod_name}\"/>" "$FS_AUTOLOAD_CONF" || continue
  sudo sed -i "s|<load module=\"${mod_name}\"/>|<!-- <load module=\"${mod_name}\"/> -->|" \
    "$FS_AUTOLOAD_CONF"
  echo "Un-autoloaded '$mod_name' - it is not built"
done

### The minimal config's "Codec Interfaces" section is empty, so only the core G.711
### (PCMU/PCMA) codecs are available - mod_opus gets built but is never loaded. Opus is what
### keeps quality sane over WiFi/mobile, where G.711 has no packet loss concealment and no
### bandwidth adaptation, so autoload it.
FS_AUTOLOAD_ADD="mod_opus"
for mod_name in $FS_AUTOLOAD_ADD; do
  if [ ! -f "$PREFIX/mod/${mod_name}.so" ]; then
    echo "ERROR: ${mod_name}.so was not built but is required" >&2
    exit 1
  fi
  ### A module's own config comes from the vanilla tree - the minimal one does not ship it,
  ### and without it the module logs an error and falls back to built-in defaults. For opus
  ### that config is what turns on FEC and VBR, which is exactly what makes it usable on WiFi.
  conf_name="${mod_name#mod_}.conf.xml"
  src_conf="$BUILD_DIR/freeswitch/conf/vanilla/autoload_configs/$conf_name"
  if [ -f "$src_conf" ] && [ ! -f "$PREFIX/conf/autoload_configs/$conf_name" ]; then
    sudo install -m 644 "$src_conf" "$PREFIX/conf/autoload_configs/$conf_name"
    echo "Installed $conf_name from the vanilla config"
  fi

  grep -q "<load module=\"${mod_name}\"/>" "$FS_AUTOLOAD_CONF" && continue
  sudo sed -i "s|<!-- Codec Interfaces -->|<!-- Codec Interfaces -->\n    <load module=\"${mod_name}\"/>|" \
    "$FS_AUTOLOAD_CONF"
  echo "Autoloaded '$mod_name'"
done

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
