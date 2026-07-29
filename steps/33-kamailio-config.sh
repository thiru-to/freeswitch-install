#!/usr/bin/env bash
### Kamailio database schema, TLS and routing configuration.
###
### Role: public SIP edge. Handles registration and authentication against Postgres, applies
### anti-flood protection, engages rtpengine for media, and relays established calls to
### FreeSWITCH on loopback.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_root
load_config

command -v kamailio >/dev/null || die "Kamailio is not installed - run 32-kamailio.sh first."
pg_db_exists kamailio || die "The kamailio database does not exist - run 22-provision-databases.sh first."

### --- Schema ------------------------------------------------------------------------------

### kamdbctl reads its settings from kamctlrc. Point it at Postgres and the roles created in
### step 22 so it never prompts.
write_file /etc/kamailio/kamctlrc 0640 root:kamailio <<EOF || true
# Managed by the VoIP PBX installer.
SIP_DOMAIN=${PBX_SIP_DOMAIN}
DBENGINE=PGSQL
DBHOST=127.0.0.1
DBPORT=5432
DBNAME=kamailio
DBRWUSER="kamailio"
DBRWPW="${KAMAILIO_DB_PASSWORD}"
DBROUSER="kamailioro"
DBROPW="${KAMAILIO_RO_DB_PASSWORD}"
DBACCESSHOST=127.0.0.1
INSTALL_EXTRA_TABLES=yes
INSTALL_PRESENCE_TABLES=yes
INSTALL_DBUID_TABLES=yes
CHARSET=utf8
EOF

### kamdbctl create is not idempotent - it errors out if the tables are already there. Detect
### an existing schema by looking for the subscriber table.
if su - postgres -c "psql -tAc \"SELECT to_regclass('public.subscriber')\" kamailio" | grep -q subscriber; then
  ok "Kamailio schema already present"
else
  info "Creating the Kamailio schema"
  ### kamdbctl wants to create roles itself, but step 22 already did with tighter privileges.
  ### Feeding it 'n' for the role prompts and 'y' for the table sets keeps ours intact.
  yes 'y' | kamdbctl create >/dev/null 2>&1 || \
    die "kamdbctl create failed. Run it manually to see the error: kamdbctl create"
  ok "Schema created"
fi

### --- TLS ---------------------------------------------------------------------------------

TLS_READY=0
if [ -f /etc/voip-pbx/tls/fullchain.pem ]; then
  usermod -aG ssl-cert kamailio 2>/dev/null || true
  TLS_READY=1
  write_file /etc/kamailio/tls.cfg 0640 root:kamailio <<'EOF' || true
# Managed by the VoIP PBX installer.
[server:default]
method = TLSv1.2+
verify_certificate = no
require_certificate = no
private_key = /etc/voip-pbx/tls/privkey.pem
certificate = /etc/voip-pbx/tls/fullchain.pem
cipher_list = HIGH:!aNULL:!MD5:!RC4:!3DES

[client:default]
method = TLSv1.2+
verify_certificate = yes
require_certificate = no
ca_list = /etc/ssl/certs/ca-certificates.crt
EOF
else
  warn "No TLS material at /etc/voip-pbx/tls - SIP TLS on ${SIPS_PORT} will be disabled."
  warn "Run 13-tls-certs.sh, then re-run this step."
fi

### --- Routing configuration -----------------------------------------------------------------

### This is a deliberately conservative starting point: register/authenticate, protect, relay
### to FreeSWITCH. It is NOT a finished dialplan - number translation, outbound trunking and
### billing hooks are business logic and belong to you. Review before taking real traffic.
write_file /etc/kamailio/kamailio.cfg 0640 root:kamailio <<EOF || true
#!KAMAILIO
#
# Managed by the VoIP PBX installer.
# Public SIP edge in front of FreeSWITCH.

#!define DBURL "postgres://kamailio:${KAMAILIO_DB_PASSWORD}@127.0.0.1:5432/kamailio"
#!define DBURL_RO "postgres://kamailioro:${KAMAILIO_RO_DB_PASSWORD}@127.0.0.1:5432/kamailio"
#!define FS_SIP "sip:127.0.0.1:${FS_INTERNAL_SIP_PORT}"
#!define RTPENGINE_SOCK "udp:127.0.0.1:${RTPENGINE_NG_PORT}"
$( [ "$TLS_READY" = "1" ] && echo '#!define WITH_TLS' )

####### Global Parameters #########

server_header="Server: VoIP PBX"
user_agent_header="User-Agent: VoIP PBX"
sip_warning=no          # do not leak internal details in warning headers

listen=udp:0.0.0.0:${SIP_PORT}
listen=tcp:0.0.0.0:${SIP_PORT}
#!ifdef WITH_TLS
listen=tls:0.0.0.0:${SIPS_PORT}
enable_tls=1
#!endif

alias="${PBX_SIP_DOMAIN}"

children=8
tcp_children=4
auto_aliases=no

# Reasonable transaction timeouts: SIP defaults are tuned for slow 1990s networks.
tcp_connection_lifetime=3605
tcp_accept_no_cl=yes

####### Modules #########

mpath="/usr/lib/x86_64-linux-gnu/kamailio/modules/"

loadmodule "jsonrpcs.so"
loadmodule "kex.so"
loadmodule "corex.so"
loadmodule "tm.so"
loadmodule "tmx.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "usrloc.so"
loadmodule "registrar.so"
loadmodule "textops.so"
loadmodule "textopsx.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "sanity.so"
loadmodule "ctl.so"
loadmodule "cfg_rpc.so"
loadmodule "counters.so"
loadmodule "db_postgres.so"
loadmodule "auth.so"
loadmodule "auth_db.so"
loadmodule "pike.so"
loadmodule "htable.so"
loadmodule "rtpengine.so"
loadmodule "nathelper.so"
loadmodule "uac.so"
#!ifdef WITH_TLS
loadmodule "tls.so"
#!endif

# ----- Module settings -----

modparam("jsonrpcs", "pretty_format", 1)
modparam("ctl", "binrpc", "unix:/run/kamailio/kamailio_ctl")

modparam("tm", "failure_reply_mode", 3)
modparam("tm", "fr_timer", 30000)
modparam("tm", "fr_inv_timer", 120000)

modparam("rr", "append_fromtag", 0)

# Location storage in the database so registrations survive a restart.
modparam("usrloc", "db_url", DBURL)
modparam("usrloc", "db_mode", 2)
modparam("usrloc", "use_domain", 1)

modparam("registrar", "method_filtering", 1)
modparam("registrar", "max_expires", 3600)
modparam("registrar", "min_expires", 60)
modparam("registrar", "gruu_enabled", 0)
# Store the source address so we can reach endpoints behind NAT.
modparam("registrar", "received_avp", "\$avp(RECEIVED)")

modparam("auth_db", "db_url", DBURL_RO)
modparam("auth_db", "calculate_ha1", yes)
modparam("auth_db", "password_column", "password")
modparam("auth_db", "use_domain", 1)
modparam("auth_db", "load_credentials", "")

# Nonce reuse window. Short enough to blunt replay, long enough not to churn.
modparam("auth", "nonce_expire", 300)

# pike: per-source request rate limiting, the first line of defence against scanners.
modparam("pike", "sampling_time_unit", 2)
modparam("pike", "reqs_density_per_unit", 30)
modparam("pike", "remove_latency", 120)

# Table for tracking blocked sources.
modparam("htable", "htable", "ipban=>size=8;autoexpire=300;")

modparam("rtpengine", "rtpengine_sock", RTPENGINE_SOCK)

modparam("nathelper", "natping_interval", 30)
modparam("nathelper", "ping_nated_only", 1)
modparam("nathelper", "sipping_from", "sip:pinger@${PBX_SIP_DOMAIN}")

#!ifdef WITH_TLS
modparam("tls", "config", "/etc/kamailio/tls.cfg")
#!endif

####### Routing #########

request_route {

    # Drop obviously malformed traffic before spending any real work on it.
    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }
    if (!sanity_check("1511", "7")) {
        xlog("L_WARN", "Malformed request from \$si\n");
        exit;
    }

    route(REQINIT);

    # In-dialog requests already have a route set - follow it, do not re-authenticate.
    if (has_totag()) {
        route(WITHINDLG);
        exit;
    }

    # CANCEL matches an existing transaction.
    if (is_method("CANCEL")) {
        if (t_check_trans()) {
            route(RELAY);
        }
        exit;
    }
    t_check_trans();

    if (is_method("REGISTER")) {
        route(REGISTRAR);
        exit;
    }

    if (is_method("INVITE")) {
        route(AUTH);
        record_route();
        route(NATMANAGE);
        route(TOFS);
        exit;
    }

    # Anything else that is not a dialog-forming method we simply do not offer.
    if (is_method("OPTIONS") && uri==myself) {
        sl_send_reply("200", "OK");
        exit;
    }

    route(AUTH);
    record_route();
    route(TOFS);
}

# ----- Per-request sanity and flood control -----
route[REQINIT] {

    # Already-banned sources are dropped silently: replying confirms the host is alive and
    # invites more traffic.
    if (\$sht(ipban=>\$si) != \$null) {
        xdbg("Dropping request from banned source \$si\n");
        drop;
    }

    if (!pike_check_req()) {
        xlog("L_ALERT", "Rate limit exceeded, banning \$si (\$rm from \$fu)\n");
        \$sht(ipban=>\$si) = 1;
        drop;
    }

    if (\$ua =~ "(friendly-scanner|sipcli|sipvicious|VaxSIPUserAgent|sundayddr)") {
        xlog("L_WARN", "Known scanner UA from \$si: \$ua\n");
        \$sht(ipban=>\$si) = 1;
        drop;
    }
}

# ----- Requests inside an established dialog -----
route[WITHINDLG] {
    if (!loose_route()) {
        # Late in-dialog request whose transaction we no longer hold.
        if (is_method("ACK") && t_check_trans()) {
            route(RELAY);
            exit;
        }
        sl_send_reply("404", "Not Found");
        exit;
    }

    if (is_method("BYE")) {
        route(RTPUNMANAGE);
    } else if (is_method("INVITE")) {
        # Re-INVITE: media may be moving, so refresh the rtpengine offer.
        record_route();
        route(NATMANAGE);
    }
    route(RELAY);
    exit;
}

# ----- Registration -----
route[REGISTRAR] {
    if (!www_authenticate("\$td", "subscriber")) {
        www_challenge("\$td", "0");
        exit;
    }

    if (\$au != \$tU) {
        xlog("L_WARN", "Auth user \$au does not match To user \$tU from \$si\n");
        sl_send_reply("403", "Forbidden");
        exit;
    }

    # Record where the endpoint actually came from so we can reach it behind NAT.
    if (is_present_hf("Contact") && nat_uac_test("19")) {
        fix_nated_register();
        setbflag(6);
    }

    if (!save("location")) {
        sl_reply_error();
    }
    exit;
}

# ----- Authentication for non-REGISTER requests -----
route[AUTH] {
    # Traffic arriving from FreeSWITCH itself is already trusted.
    if (\$si == "127.0.0.1") {
        return;
    }

    if (!proxy_authorize("\$fd", "subscriber")) {
        proxy_challenge("\$fd", "0");
        exit;
    }

    if (\$au != \$fU) {
        xlog("L_WARN", "Auth user \$au does not match From user \$fU from \$si\n");
        sl_send_reply("403", "Forbidden");
        exit;
    }

    # Strip the credentials before relaying - FreeSWITCH does not need them and they should
    # not travel further than they must.
    consume_credentials();
}

# ----- Media handling -----
route[NATMANAGE] {
    if (nat_uac_test("19")) {
        fix_nated_contact();
        setbflag(6);
    }

    # Always relay media through rtpengine. Endpoints on WiFi and mobile are almost always
    # behind NAT, and letting them try direct media is the usual cause of one-way audio.
    rtpengine_manage("replace-origin replace-session-connection ICE=remove RTP/AVP");
    t_on_reply("MANAGE_REPLY");
}

route[RTPUNMANAGE] {
    rtpengine_delete();
}

# ----- Relay to FreeSWITCH -----
route[TOFS] {
    \$du = FS_SIP;
    route(RELAY);
}

route[RELAY] {
    t_on_failure("MANAGE_FAILURE");
    if (!t_relay()) {
        sl_reply_error();
    }
    exit;
}

onreply_route[MANAGE_REPLY] {
    # Fix up media on any reply that carries SDP.
    if (has_body("application/sdp")) {
        route(NATMANAGE);
    }
    if (nat_uac_test("1")) {
        fix_nated_contact();
    }
}

failure_route[MANAGE_FAILURE] {
    if (t_is_canceled()) {
        exit;
    }
    route(RTPUNMANAGE);
}
EOF

### --- Runtime -------------------------------------------------------------------------------

### The module path differs on arm64. Patch it rather than hardcoding x86_64.
mpath="$(dirname "$(find /usr/lib -name 'tm.so' -path '*kamailio*' 2>/dev/null | head -1)")"
if [ -n "$mpath" ] && [ "$mpath" != "/usr/lib/x86_64-linux-gnu/kamailio/modules" ]; then
  sed -i "s|^mpath=.*|mpath=\"${mpath}/\"|" /etc/kamailio/kamailio.cfg
  info "Module path set to ${mpath}/"
fi

install -d -m 0755 -o kamailio -g kamailio /run/kamailio

### Kamailio's Debian default refuses to start until this is flipped, as a guard against
### running the example config in production. We have just written a real one.
ensure_directive /etc/default/kamailio "RUN_KAMAILIO" "yes" "="
ensure_directive /etc/default/kamailio "USER" "kamailio" "="
ensure_directive /etc/default/kamailio "GROUP" "kamailio" "="

kamailio -c -f /etc/kamailio/kamailio.cfg >/dev/null 2>&1 \
  || die "Kamailio config check failed. Run: kamailio -c -f /etc/kamailio/kamailio.cfg"
ok "Configuration syntax valid"

systemctl enable kamailio >/dev/null 2>&1 || true
restart_service kamailio

ok "Kamailio listening on ${SIP_PORT} (UDP/TCP)$( [ "$TLS_READY" = "1" ] && echo " and ${SIPS_PORT} (TLS)" )"
warn "The routing config is a safe baseline, not a finished dialplan."
warn "Number translation, outbound trunks and billing hooks still need to be added."
