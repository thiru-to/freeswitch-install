#!/usr/bin/env bash

# Install Kamailio 6.1 for Debian from package, not source. 
# apt update && apt install -y wget gpg
# wget -O- http://deb.kamailio.org/kamailiodebkey.gpg | gpg --dearmor > /usr/share/keyrings/kamailio.gpg
# echo "deb [signed-by=/usr/share/keyrings/kamailio.gpg] http://deb.kamailio.org/kamailio61 trixie main" > /etc/apt/sources.list.d/kamailio.list
# apt update
# apt install -y kamailio kamailio-postgres-modules kamailio-tls-modules kamailio-lua-modules
# systemctl enable kamailio
# systemctl start kamailio
# systemctl status kamailio
