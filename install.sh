FS_VERSION="${1:-v1.10.13}"
BUILD_DIR="/usr/src"
PREFIX="/usr/local/freeswitch"
JOBS="$(nproc)"

sudo apt -y update
sudo apt -y upgrade
sudo apt -y install htop curl git sngrep ca-certificates
sudo apt -y install gpg vim-tiny tcpdump rsyslog apt-transport-https gnupg2 lsb-release wget


### Freeswitch Dependendcies
sudo apt update && sudo apt -y install \
  git build-essential automake autoconf wget libtool \
  libncurses-dev libjpeg-dev libsqlite3-dev libcurl4-openssl-dev \
  libpcre2-dev libspeexdsp-dev libspeex-dev libldns-dev libedit-dev \
  libssl-dev zlib1g-dev liblua5.2-dev libopus-dev libsndfile1-dev \
  libavformat-dev libswscale-dev libtool-bin libtiff-dev cmake uuid-dev libpq-dev libshout3-dev libmp3lame-dev nasm yasm libnode-dev
    apt -y update

### Clone repositories.
sudo git clone https://github.com/signalwire/libks.git && 
sudo git clone https://github.com/freeswitch/spandsp.git && 
sudo git clone https://github.com/signalwire/freeswitch.git &&
sudo git clone https://github.com/freeswitch/sofia-sip.git &&
sudo git clone https://github.com/thiru-to/freeswitch-install.git


### install spandsp
cd /usr/src/spandsp
sudo ./bootstrap.sh
sudo ./configure
sudo make -j$(nproc)
sudo make install


### Install libks
cd /usr/src/libks
sudo cmake .
sudo make -j$(nproc)
sudo make install


### Install sofia-sip
cd /usr/src/sofia-sip
sudo ./bootstrap.sh 
sudo ./configure --enable-debug
sudo make && sudo make install

### Install freeswitch
cd /usr/src/freeswitch
sudo ./bootstrap.sh -j


sed -i modules.conf -e s:'#applications/mod_callcenter:applications/mod_callcenter:'
sed -i modules.conf -e s:'#applications/mod_cidlookup:applications/mod_cidlookup:'
sed -i modules.conf -e s:'#applications/mod_memcache:applications/mod_memcache:'
sed -i modules.conf -e s:'#applications/mod_hiredis:applications/mod_hiredis:'
sed -i modules.conf -e s:'#applications/mod_curl:applications/mod_curl:'
sed -i modules.conf -e s:'#formats/mod_shout:formats/mod_shout:'
sed -i modules.conf -e s:'#formats/mod_pgsql:formats/mod_pgsql:'


sudo sed -i 's|^#applications/mod_easyroute|applications/mod_easyroute|' modules.conf
sudo sed -i 's|^#applications/mod_nibblebill|applications/mod_nibblebill|' modules.conf
sudo sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|' modules.conf
sudo sed -i 's|^#event_handlers/mod_fail2ban|event_handlers/mod_fail2ban|' modules.conf
sudo sed -i 's|^#formats/mod_shout|formats/mod_shout|' modules.conf
sudo sed -i modules.conf -e s:'#formats/mod_pgsql:formats/mod_pgsql:'
sudo sed -i 's|^#xml_int/mod_xml_curl|xml_int/mod_xml_curl|' modules.conf



sed -i modules.conf -e s:'endpoints/mod_skinny:#endpoints/mod_skinny:'
sed -i modules.conf -e s:'endpoints/mod_verto:#endpoints/mod_verto:'
sed -i modules.conf -e s:'applications/mod_say_es:#applications/mod_say_es:'
sed -i modules.conf -e s:'applications/mod_say_fr:#applications/mod_say_fr:'
sed -i modules.conf -e s:'applications/mod_av:#applications/mod_av:'
sed -i modules.conf -e s:'xml_int/mod_xml_rpc:#xml_int/mod_xml_rpc:'
sudo sed -i 's|^#languages/mod_v8|languages/mod_v8|' modules.conf


sudo ./configure -C -q ./configure --prefix="${PREFIX}" \
--disable-dependency-tracking --enable-debug --enable-core-pgsql-support --with-openssl


sudo make -j$(nproc)
sudo make install


### Install freeswitch sounds
sudo make sounds-install moh-install
sudo make cd-sounds-install
sudo make cd-moh-install 

### Create freeswitch group & user and give permissions.
sudo groupadd freeswitch
sudo adduser --quiet --system --home ${PREFIX} --comment 'FreeSWITCH open source softswitch' --ingroup freeswitch freeswitch --disabled-password
sudo chown -R freeswitch:freeswitch ${PREFIX}
sudo chmod -R ug=rwX,o= ${PREFIX}
sudo chmod -R u=rwx,g=rx ${PREFIX}/bin/*


sudo ln -sf "${PREFIX}/bin/freeswitch" /usr/local/bin/freeswitch
sudo ln -sf "${PREFIX}/bin/fs_cli"     /usr/local/bin/fs_cli


### Create freeswitch service
sudo cat $BUILD_DIR/freeswitch-install/resources/freeswitch.service > /etc/systemd/system/freeswitch.service

sudo systemctl daemon-reload
sudo systemctl enable --now freeswitch



