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
  ### Apply the schema files directly rather than running `kamdbctl create`.
  ###
  ### kamdbctl insists on creating the database and the roles itself, and both already exist -
  ### 22-provision-databases.sh made them with tighter privileges than kamdbctl would. It fails
  ### on "database already exists" before it ever reaches the tables. It also wants credentials
  ### in ~/.pgpass for a TCP connection we do not otherwise need.
  ###
  ### Applying the per-module SQL is deterministic, idempotent to re-run in the sense that it
  ### either succeeds or fails loudly, and makes the module-to-table mapping explicit: each
  ### file here exists because a module in kamailio.cfg requires it.
  SCHEMA_DIR="/usr/share/kamailio/postgres"
  [ -d "$SCHEMA_DIR" ] || die "Kamailio schema files not found at $SCHEMA_DIR"

  ### standard covers version/usrloc/subscriber-adjacent core tables. The rest map one-to-one
  ### onto loadmodule lines: drop a module and its schema stops being needed.
  KAM_SCHEMAS="standard auth_db usrloc domain permissions dispatcher drouting dialog acc"

  info "Applying the Kamailio schema"
  for schema in $KAM_SCHEMAS; do
    f="$SCHEMA_DIR/${schema}-create.sql"
    if [ ! -f "$f" ]; then
      warn "  no schema file for ${schema} - skipping"
      continue
    fi
    if su - postgres -c "psql -v ON_ERROR_STOP=1 -q -d kamailio -f '$f'" >/dev/null 2>&1; then
      info "  ${schema}"
    else
      die "Failed applying ${schema} schema. Run: su - postgres -c \"psql -d kamailio -f $f\""
    fi
  done

  ### The tables are owned by postgres after this; Kamailio connects as the kamailio role and
  ### needs to actually use them.
  su - postgres -c "psql -q -d kamailio -c \
    'GRANT ALL ON ALL TABLES IN SCHEMA public TO kamailio;
     GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO kamailio;
     GRANT SELECT ON ALL TABLES IN SCHEMA public TO kamailioro;'" >/dev/null

  ok "Schema applied"
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
# ca_path, not ca_list. Kamailio's tls module fails to load Debian's concatenated
# ca-certificates.crt ("nested asn1 error") even though the bundle itself is valid; the
# hashed-directory form is what OpenSSL handles reliably. Only used for OUTBOUND TLS - to a
# carrier over SIPS - never for the endpoints we serve.
ca_path = /etc/ssl/certs
EOF
else
  warn "No TLS material at /etc/voip-pbx/tls - SIP TLS on ${SIPS_PORT} will be disabled."
  warn "Run 13-tls-certs.sh, then re-run this step."
fi

### --- Feature detection ---------------------------------------------------------------------

### WebRTC rides on the same TLS material as SIP TLS - a browser will not open a WSS socket
### to an untrusted certificate, so there is no useful "WebRTC without TLS" mode.
WEBRTC_READY=0
if [ "${ENABLE_WEBRTC:-1}" = "1" ]; then
  if [ "$TLS_READY" = "1" ]; then
    WEBRTC_READY=1
    ok "WebRTC enabled - WSS on ${WSS_PORT}"
  else
    warn "WebRTC needs TLS. Run 13-tls-certs.sh first."
  fi
fi

### The stirshaken module is a source build (33-stir-shaken.sh); its absence is normal.
STIRSHAKEN_READY=0
if [ "${ENABLE_STIR_SHAKEN:-0}" = "1" ]; then
  mpath_probe="$(dirname "$(find /usr/lib -name 'tm.so' -path '*kamailio*' 2>/dev/null | head -1)")"
  if [ -n "$mpath_probe" ] && [ -f "$mpath_probe/stirshaken.so" ] && [ -f /etc/kamailio/stirshaken.cfg ]; then
    STIRSHAKEN_READY=1
    ok "STIR/SHAKEN enabled"
  else
    warn "ENABLE_STIR_SHAKEN is set but the module is not built - run 33-stir-shaken.sh."
  fi
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
#!define FS_SIP "sip:${FS_HOST}:${FS_INTERNAL_SIP_PORT}"
#!define KAM_EGRESS_PORT_D ${KAM_EGRESS_PORT}
#!define RTPENGINE_SOCK "udp:127.0.0.1:${RTPENGINE_NG_PORT}"
$( [ "$TLS_READY" = "1" ] && echo '#!define WITH_TLS' )
$( [ "$WEBRTC_READY" = "1" ] && echo '#!define WITH_WEBRTC' )
$( [ "$STIRSHAKEN_READY" = "1" ] && echo '#!define WITH_STIRSHAKEN' )

####### Global Parameters #########

server_header="Server: VoIP PBX"
user_agent_header="User-Agent: VoIP PBX"
sip_warning=no          # do not leak internal details in warning headers

listen=udp:0.0.0.0:${SIP_PORT}
listen=tcp:0.0.0.0:${SIP_PORT}

# Egress listener: the port FreeSWITCH sends outbound calls back to. Bound to the internal
# address only and never exposed - steps/11-firewall.sh does not open it. Keeping it distinct
# from SIP_PORT is one of the two independent signals that separate the ingress pass from the
# egress pass; the other is the source address. Neither alone is load-bearing, which matters
# once roles split across hosts.
listen=udp:${FS_HOST}:${KAM_EGRESS_PORT}
listen=tcp:${FS_HOST}:${KAM_EGRESS_PORT}
#!ifdef WITH_TLS
listen=tls:0.0.0.0:${SIPS_PORT}
enable_tls=1
#!endif
#!ifdef WITH_WEBRTC
# Browsers speak SIP over a secure WebSocket. Separate port from SIP TLS so a browser client
# and a hardware phone are not competing for the same listener.
listen=tls:0.0.0.0:${WSS_PORT}
#!endif

alias="${PBX_SIP_DOMAIN}"

children=8
tcp_children=4
auto_aliases=no

# Accounting flags, referenced by the acc module and set in the routing logic.
#!define FLT_ACC 1
#!define FLT_ACCMISSED 2
#!define FLT_ACCFAILED 3
#!define FLT_WEBRTC 4
#!define FLT_EGRESS 5

# Branch flag marking a contact behind NAT. usrloc must be told which flag this is, or
# nathelper refuses to start with ping_nated_only enabled - the two have to agree and a bare
# literal in setbflag() is how they silently stop agreeing.
#!define FLB_NATB 6

# Concurrent calls allowed per account before new ones are rejected. This is the single most
# effective control against toll fraud: a stolen SIP credential is monetised by placing many
# simultaneous international calls, and a cap turns a five-figure overnight bill into a
# handful of calls plus an alert.
#!define MAX_CONCURRENT_CALLS 10

# Consecutive auth failures from one source before it is blocked outright.
#!define MAX_AUTH_FAILURES 10

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
loadmodule "acc.so"
loadmodule "dialog.so"
loadmodule "permissions.so"
loadmodule "dispatcher.so"
loadmodule "drouting.so"
#!ifdef WITH_TLS
loadmodule "tls.so"
#!endif
#!ifdef WITH_WEBRTC
loadmodule "xhttp.so"
loadmodule "websocket.so"
#!endif
#!ifdef WITH_STIRSHAKEN
# Module params live in the fragment written by 33-stir-shaken.sh.
import_file "/etc/kamailio/stirshaken.cfg"
#!endif

# ----- Module settings -----

modparam("jsonrpcs", "pretty_format", 1)
modparam("ctl", "binrpc", "unix:/run/kamailio/kamailio_ctl")

modparam("tm", "failure_reply_mode", 3)
modparam("tm", "fr_timer", 30000)
modparam("tm", "fr_inv_timer", 120000)

modparam("rr", "append_fromtag", 0)

# uac defaults to AUTO From-restore, which requires append_fromtag=1 above and refuses to
# start without it. We never rewrite the From header - uac is loaded for uac_reg, so that
# trunks with authMode=register can register to a carrier - so the restore machinery is
# simply not wanted.
modparam("uac", "restore_mode", "none")

# Location storage in the database so registrations survive a restart.
modparam("usrloc", "db_url", DBURL)
modparam("usrloc", "db_mode", 2)
modparam("usrloc", "use_domain", 1)
# Must match FLB_NATB. nathelper reads this to know which registrations need keepalives.
modparam("usrloc", "nat_bflag", FLB_NATB)

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

# Tables for blocked sources and for counting concurrent calls per account.
modparam("htable", "htable", "ipban=>size=8;autoexpire=300;")
modparam("htable", "htable", "concurrent=>size=10;autoexpire=86400;")
modparam("htable", "htable", "authfail=>size=10;autoexpire=1800;")

# ----- Accounting (CDR) -----
# Without this there is no record of who called whom. Billing, dispute resolution and fraud
# investigation all depend on it, so it writes to the database rather than only to syslog.
modparam("acc", "db_url", DBURL)
modparam("acc", "db_flag", FLT_ACC)
modparam("acc", "db_missed_flag", FLT_ACCMISSED)
modparam("acc", "failed_transaction_flag", FLT_ACCFAILED)
modparam("acc", "log_level", 2)
modparam("acc", "early_media", 0)
modparam("acc", "report_ack", 0)
modparam("acc", "report_cancels", 0)
modparam("acc", "detect_direction", 0)
# Extra columns make the CDR useful to the billing side without a second lookup.
modparam("acc", "db_extra", "src_user=\$fU;src_domain=\$fd;dst_user=\$rU;dst_domain=\$rd;src_ip=\$si;dialog_id=\$dlg_var(dlgid)")

# ----- Dialog tracking -----
# Required to know how many calls an account has up right now, which is what makes the
# concurrent-call limit below possible.
modparam("dialog", "enable_stats", 1)
modparam("dialog", "hash_size", 4096)
modparam("dialog", "detect_spirals", 1)
modparam("dialog", "default_timeout", 21600)
modparam("dialog", "early_timeout", 300)
modparam("dialog", "noack_timeout", 180)
modparam("dialog", "end_timeout", 60)
modparam("dialog", "db_mode", 0)

# ----- Trunk / carrier authentication by IP -----
# Carriers do not register; they are identified by source address. The address table is the
# single source of truth, and 14-responsive-firewall.sh reads the same table so the firewall
# and the proxy cannot disagree about who is a trunk.
modparam("permissions", "db_url", DBURL_RO)
modparam("permissions", "db_mode", 1)
modparam("permissions", "address_table", "address")

# ----- Carrier routing -----
# drouting holds the gateways and rules the portal projects from our trunk/outbound_route
# tables. Used only on the egress pass; failure_route retries the next gateway, which is how
# one dead carrier stops being an outage.
modparam("drouting", "db_url", DBURL_RO)
modparam("drouting", "drd_table", "dr_gateways")
modparam("drouting", "drr_table", "dr_rules")
modparam("drouting", "drg_table", "dr_groups")
modparam("drouting", "drl_table", "dr_gw_lists")
modparam("drouting", "use_domain", 1)
# Keep the ruleset in memory and reload on demand (kamcmd drouting.reload) rather than hitting
# the database per call - this is the egress hot path.
modparam("drouting", "sort_order", 0)

# ----- FreeSWITCH pool -----
# One entry today, but going through dispatcher means adding a second media node later is a
# database row rather than a config change. OPTIONS probing takes a dead node out of rotation
# instead of sending calls into a black hole.
modparam("dispatcher", "db_url", DBURL_RO)
modparam("dispatcher", "table_name", "dispatcher")
modparam("dispatcher", "flags", 2)
modparam("dispatcher", "ds_probing_mode", 1)
modparam("dispatcher", "ds_ping_method", "OPTIONS")
modparam("dispatcher", "ds_ping_interval", 30)
modparam("dispatcher", "ds_probing_threshold", 2)
modparam("dispatcher", "ds_inactive_threshold", 1)

modparam("rtpengine", "rtpengine_sock", RTPENGINE_SOCK)

# Must be the SAME value as registrar's received_avp below - nathelper reads the AVP registrar
# writes, and it refuses to start if the two are not both set. This is the third parameter in
# this config that has to agree across two modules (see also nat_bflag), so they are kept
# adjacent to their partner rather than grouped by module.
modparam("nathelper", "received_avp", "\$avp(RECEIVED)")
modparam("nathelper", "natping_interval", 30)
modparam("nathelper", "ping_nated_only", 1)
modparam("nathelper", "sipping_from", "sip:pinger@${PBX_SIP_DOMAIN}")

#!ifdef WITH_TLS
modparam("tls", "config", "/etc/kamailio/tls.cfg")
#!endif

#!ifdef WITH_WEBRTC
# Browsers sit behind NAT and aggressive middleboxes. Kamailio pings the socket so the
# connection is not silently reaped between calls, which is the usual cause of a browser
# client that looks registered but cannot be reached.
modparam("websocket", "keepalive_mechanism", 1)
modparam("websocket", "keepalive_timeout", 30)
modparam("websocket", "keepalive_interval", 1)
modparam("websocket", "keepalive_processes", 1)
modparam("websocket", "sub_protocols", 1)
modparam("nathelper", "nortpproxy_str", "")
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

    # ---- Which pass is this? -------------------------------------------------------------
    #
    # Kamailio sees every call TWICE: once from the endpoint (ingress) and once from
    # FreeSWITCH heading for a carrier (egress). Nearly every subtle bug in this topology comes
    # from confusing the two, so the test is explicit and uses both available signals.
    if (\$Rp == KAM_EGRESS_PORT_D) {
        setflag(FLT_EGRESS);
    }

    route(REQINIT);

    # In-dialog requests already have a route set - follow it, do not re-authenticate.
    # Both passes record-route, so the route set contains Kamailio twice and in-dialog
    # requests traverse it twice. That is correct and necessary; getting loose_route wrong
    # here leaks FreeSWITCH channels AND leaves the concurrent counter permanently
    # incremented, which then locks the tenant out via their own fraud cap.
    if (has_totag()) {
        route(WITHINDLG);
        exit;
    }

    if (is_method("CANCEL")) {
        if (t_check_trans()) {
            route(RELAY);
        }
        exit;
    }
    t_check_trans();

    if (is_method("REGISTER")) {
        # Registration only ever arrives on the public side.
        if (isflagset(FLT_EGRESS)) {
            xlog("L_WARN", "REGISTER on the egress port from \$si - rejecting\n");
            sl_send_reply("403", "Forbidden");
            exit;
        }
        route(REGISTRAR);
        exit;
    }

    if (is_method("INVITE")) {
        if (isflagset(FLT_EGRESS)) {
            route(EGRESS);
        } else {
            route(INGRESS);
        }
        exit;
    }

    if (is_method("OPTIONS") && uri==myself) {
        sl_send_reply("200", "OK");
        exit;
    }

    if (!isflagset(FLT_EGRESS)) {
        route(AUTH);
    }
    record_route();
    route(TOFS);
}

# ----- Ingress: endpoint -> FreeSWITCH ------------------------------------------------------
#
# This is the ONLY pass that counts dialogs and writes CDR. Doing either on the egress pass as
# well would increment the concurrent counter twice per call - so MAX_CONCURRENT_CALLS=10 would
# actually trip at 5 - and write duplicate accounting rows, i.e. double billing.
route[INGRESS] {
    route(AUTH);
    route(FRAUD);

#!ifdef WITH_STIRSHAKEN
    # Verification belongs on ingress - this is where a call from another carrier arrives with
    # an Identity header. Signing is the egress pass's job.
    route(STIRSHAKEN_IN);
#!endif

    dlg_manage();

    # Stash identity on the dialog: \$au is not available once the transaction moves on, and
    # the lifecycle routes need it to decrement the right counter.
    \$dlg_var(acct) = \$au;
    if (\$dlg_var(acct) == "") {
        \$dlg_var(acct) = \$fU;
    }
    \$dlg_var(tenant) = \$fd;

    setflag(FLT_ACC);
    setflag(FLT_ACCMISSED);
    setflag(FLT_ACCFAILED);

    record_route();
    route(NATMANAGE);
    route(TOFS);
}

# ----- Egress: FreeSWITCH -> carrier --------------------------------------------------------
#
# Deliberately does NOT call dlg_manage() or set the accounting flags - see route[INGRESS].
#
# It DOES re-run the fraud checks, because this is where carrier spend is actually incurred and
# because an ingress-only check would be bypassed entirely if FreeSWITCH were ever compromised
# or misconfigured.
route[EGRESS] {
    # Only FreeSWITCH may use this path. The port is internal-only, but check the source too:
    # defence in depth costs nothing here and the consequence of being wrong is toll fraud.
    if (!allow_source_address("1") && \$si != "${FS_HOST}") {
        xlog("L_ALERT", "Egress attempt from unexpected source \$si - rejecting\n");
        sl_send_reply("403", "Forbidden");
        exit;
    }

    # Tenant identity does not survive the B2BUA: FreeSWITCH rebuilds the INVITE, so \$fU and
    # \$au are whatever it chose. The dialplan sets these headers precisely so that per-tenant
    # policy, CDR attribution and STIR attestation still work out here.
    \$var(tenant) = \$hdr(X-Tenant-ID);
    \$var(authuser) = \$hdr(X-Auth-User);

    if (\$var(tenant) == "") {
        xlog("L_WARN", "Egress INVITE with no X-Tenant-ID from \$si to \$rU - per-tenant policy cannot apply\n");
    }

    # Emergency calls bypass every restriction. Matched FIRST, before fraud checks and before
    # any route permission - a 911 call blocked by our own toll-fraud cap is the worst failure
    # this system could have. FreeSWITCH marks these on the leg.
    if (\$hdr(X-Emergency) == "true") {
        xlog("L_NOTICE", "EMERGENCY egress \$rU for tenant \$var(tenant)\n");
        route(TOTRUNK);
        exit;
    }

    route(FRAUD);

#!ifdef WITH_STIRSHAKEN
    # Signing happens here, at true egress. This is the only place the Identity header
    # survives, because FreeSWITCH would rebuild the INVITE and discard it.
    route(STIRSHAKEN_OUT);
#!endif

    record_route();
    route(NATMANAGE);
    route(TOTRUNK);
}

# ----- Carrier selection --------------------------------------------------------------------
route[TOTRUNK] {
    # drouting picks the gateway from dr_rules/dr_gateways, which the portal projects from our
    # trunk and outbound_route tables. Centralised failover is the one thing the sandwich does
    # strictly better than letting FreeSWITCH dial carriers itself.
    if (!do_routing("0")) {
        xlog("L_WARN", "No carrier route for \$rU (tenant \$var(tenant))\n");
        send_reply("404", "No route to destination");
        exit;
    }
    t_on_failure("MANAGE_CARRIER_FAILOVER");
    route(RELAY);
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
    # Both passes record-route, so a sandwiched dialog carries TWO Kamailio entries in its
    # route set and every in-dialog request traverses this twice. loose_route() handles that
    # correctly on its own - the thing to avoid is short-circuiting it. If BYE ever fails to
    # route, FreeSWITCH channels leak AND the concurrent counter never decrements, which locks
    # the tenant out of their own service via the fraud cap with no obvious cause.
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

        # A T.38 switch arrives as an in-dialog re-INVITE with an image/udptl stream rather
        # than audio. Forcing the usual RTP/AVP flags onto it rewrites the SDP into something
        # neither end asked for and the fax fails - so hand it to rtpengine untouched and let
        # its T.38 gateway (Debian links libspandsp) do the work.
        if (has_body("application/sdp") && search_body("m=image")) {
            xlog("L_INFO", "T.38 re-INVITE for \$ci - passing SDP through\n");
            rtpengine_manage("replace-origin replace-session-connection");
        } else {
            route(NATMANAGE);
        }
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
        setbflag(FLB_NATB);
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

    # Carriers and gateways authenticate by source address, not credentials - they never
    # register and have no password to offer.
    if (allow_source_address("1")) {
        xlog("L_INFO", "Trusted peer \$si (\$rm to \$rU)\n");
        setflag(FLT_ACC);
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

# ----- Toll fraud controls -----
#
# Fraud on a SIP platform is almost always the same shape: credentials are stolen, then used
# to place as many simultaneous international calls as the system will allow, usually
# overnight and usually to premium-rate ranges. These checks are cheap and cut off the
# economics of that attack.
route[FRAUD] {

    # Concurrent call ceiling per account.
    \$var(caller) = \$au;
    if (\$var(caller) == "") {
        \$var(caller) = \$fU;
    }
    \$var(active) = \$sht(concurrent=>\$var(caller));
    if (\$var(active) >= MAX_CONCURRENT_CALLS) {
        xlog("L_ALERT", "FRAUD: \$var(caller) at concurrent limit (\$var(active)) from \$si to \$rU\n");
        sl_send_reply("486", "Busy Here");
        exit;
    }

    # Premium-rate and high-risk international ranges, blocked by default. These carry the
    # overwhelming majority of fraud loss and almost no legitimate business traffic. Remove a
    # prefix here deliberately if a customer genuinely calls it.
    if (\$rU =~ "^(\\+?00?)(88213|88216|88218|88219|239|247|252|253|254|255|256|257|260|261|262|263|265|266|267|268|269|290|291|297|298|299|350|376|377|378|380|381|382|383|385|386|387|389|420|421|423|500|501|502|503|504|505|506|507|508|509|590|591|592|593|594|595|596|597|598|599|670|672|673|674|675|676|677|678|679|680|681|682|683|685|686|687|688|689|690|691|692|850|870|878|880|881|882|883|886|960|961|963|964|967|968|970|971|972|973|974|975|976|977|992|993|994|995|996|998)") {
        xlog("L_ALERT", "FRAUD: \$var(caller) blocked high-risk destination \$rU from \$si\n");
        sl_send_reply("403", "Destination Not Permitted");
        exit;
    }

    return;
}

# ----- Media handling -----
route[NATMANAGE] {
    if (nat_uac_test("19")) {
        fix_nated_contact();
        setbflag(FLB_NATB);
    }

    # Always relay media through rtpengine. Endpoints on WiFi and mobile are almost always
    # behind NAT, and letting them try direct media is the usual cause of one-way audio.
#!ifdef WITH_WEBRTC
    # A browser leg is DTLS-SRTP over RTP/SAVPF with ICE; FreeSWITCH speaks plain RTP/AVP.
    # rtpengine bridges the two, which is why FreeSWITCH needs no WebRTC support of its own
    # (and why mod_verto stays disabled). Remember which side was the browser so the reply
    # can be converted back - the reply travels the other way and needs the inverse flags.
    if (proto == WS || proto == WSS) {
        \$dlg_var(webrtc) = "1";
        setflag(FLT_WEBRTC);
        rtpengine_manage("replace-origin replace-session-connection ICE=remove RTP/AVP");
    } else {
        rtpengine_manage("replace-origin replace-session-connection ICE=remove RTP/AVP");
    }
#!else
    rtpengine_manage("replace-origin replace-session-connection ICE=remove RTP/AVP");
#!endif
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
#!ifdef WITH_WEBRTC
        # Answering a browser: hand it back DTLS-SRTP with ICE candidates. DTLS=passive makes
        # rtpengine wait for the browser to start the handshake, which is what browsers expect.
        if (\$dlg_var(webrtc) == "1") {
            rtpengine_manage("replace-origin replace-session-connection ICE=force DTLS=passive UDP/TLS/RTP/SAVPF");
        } else {
            route(NATMANAGE);
        }
#!else
        route(NATMANAGE);
#!endif
    }
    if (nat_uac_test("1")) {
        fix_nated_contact();
    }
}

#!ifdef WITH_WEBRTC
####### WebSocket transport #########
#
# Browsers open a normal HTTPS connection and ask to upgrade it. xhttp catches the plain HTTP
# request; websocket completes the handshake and everything after that is SIP.

event_route[xhttp:request] {
    set_reply_close();
    set_reply_no_connect();

    if (\$hdr(Upgrade) =~ "websocket" && \$hdr(Connection) =~ "Upgrade" && \$rm =~ "GET") {
        # Only serve the WSS listener - refuse an upgrade attempt on a plain port.
        if (\$Rp != ${WSS_PORT}) {
            xlog("L_WARN", "WebSocket upgrade attempted on port \$Rp from \$si\n");
            xhttp_reply("403", "Forbidden", "", "");
            exit;
        }
        if (ws_handle_handshake()) {
            exit;
        }
    }

    xhttp_reply("404", "Not Found", "", "");
}

event_route[websocket:closed] {
    xlog("L_INFO", "WebSocket connection from \$si closed\n");
}
#!endif

#!ifdef WITH_STIRSHAKEN
####### STIR/SHAKEN #########

# Inbound: check the Identity header and record the result. The verdict is attached to the
# call rather than used to reject it - dropping unsigned calls outright would block a large
# share of legitimate traffic today. Surface it to the user or the dialplan instead.
route[STIRSHAKEN_IN] {
    if (!is_present_hf("Identity")) {
        \$dlg_var(attest) = "none";
        xlog("L_INFO", "STIR: no Identity header from \$si (\$fU -> \$rU)\n");
        return;
    }

    if (stirshaken_check_identity()) {
        \$dlg_var(attest) = "verified";
        xlog("L_INFO", "STIR: verified \$fU -> \$rU from \$si\n");
    } else {
        \$dlg_var(attest) = "failed";
        xlog("L_WARN", "STIR: VERIFICATION FAILED \$fU -> \$rU from \$si\n");
        # Pass the failure downstream so the dialplan can label or divert the call.
        append_hf("X-Attestation-Result: failed\r\n");
    }
    return;
}

# Outbound: sign calls we originate. Attestation must reflect what we actually know -
# claiming A for traffic you cannot vouch for is a compliance problem, not a shortcut.
route[STIRSHAKEN_OUT] {
    if (!is_method("INVITE") || is_present_hf("Identity")) {
        return;
    }
    # Only sign for a caller we authenticated and whose number we issued.
    if (\$au == "") {
        return;
    }
    stirshaken_add_identity("${STIR_SHAKEN_X5U:-}", "${STIR_SHAKEN_ATTEST:-B}",
                            "\$fU", "\$rU", "${STIR_SHAKEN_ORIGID:-}");
    return;
}
#!endif

failure_route[MANAGE_FAILURE] {
    if (t_is_canceled()) {
        exit;
    }
    route(RTPUNMANAGE);
}

# Carrier failover. drouting keeps an ordered list; on a 5xx or timeout we try the next one
# rather than failing the call because a single carrier is having a bad day. Media must be
# re-offered on the retry or the new leg carries the old SDP.
failure_route[MANAGE_CARRIER_FAILOVER] {
    if (t_is_canceled()) {
        exit;
    }
    if (t_check_status("5[0-9][0-9]") || t_branch_timeout()) {
        if (use_next_gw()) {
            xlog("L_WARN", "Carrier failed for \$rU - retrying next gateway\n");
            route(NATMANAGE);
            route(RELAY);
            exit;
        }
        xlog("L_ERR", "All carriers exhausted for \$rU\n");
    }
    route(RTPUNMANAGE);
}

####### Dialog lifecycle #########
#
# These maintain the per-account concurrent call counter that route[FRAUD] reads. The
# decrement must cover every way a call can end - answered and hung up, cancelled, or
# abandoned - or the count drifts upwards and eventually locks an account out of its own
# service. dialog:failed covers the last case.

event_route[dialog:start] {
    \$var(acct) = \$dlg_var(acct);
    if (\$var(acct) != "") {
        \$sht(concurrent=>\$var(acct)) = \$sht(concurrent=>\$var(acct)) + 1;
        xlog("L_INFO", "Call started for \$var(acct), now \$sht(concurrent=>\$var(acct)) concurrent\n");
    }
}

event_route[dialog:end] {
    \$var(acct) = \$dlg_var(acct);
    if (\$var(acct) != "" && \$sht(concurrent=>\$var(acct)) > 0) {
        \$sht(concurrent=>\$var(acct)) = \$sht(concurrent=>\$var(acct)) - 1;
    }
}

event_route[dialog:failed] {
    \$var(acct) = \$dlg_var(acct);
    if (\$var(acct) != "" && \$sht(concurrent=>\$var(acct)) > 0) {
        \$sht(concurrent=>\$var(acct)) = \$sht(concurrent=>\$var(acct)) - 1;
    }
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

### --- Seed the routing tables ---------------------------------------------------------------

### dispatcher holds the FreeSWITCH pool. Seeding it here means the proxy has somewhere to
### send calls on a fresh install; adding a second media server later is an INSERT.
if ! su - postgres -c "psql -tAq -d kamailio -c \"SELECT 1 FROM dispatcher WHERE destination='sip:127.0.0.1:${FS_INTERNAL_SIP_PORT}'\"" 2>/dev/null | grep -q 1; then
  if su - postgres -c "psql -q -d kamailio -c \
      \"INSERT INTO dispatcher (setid, destination, flags, priority, description)
        VALUES (1, 'sip:127.0.0.1:${FS_INTERNAL_SIP_PORT}', 0, 0, 'local freeswitch')\"" >/dev/null 2>&1; then
    info "Seeded the dispatcher with the local FreeSWITCH"
  else
    warn "Could not seed the dispatcher table - add the FreeSWITCH destination manually."
  fi
fi

### The address table drives both permissions (who may send us calls without registering) and
### the responsive firewall. It starts empty: adding a carrier is a deliberate act.
if su - postgres -c "psql -tAq -d kamailio -c \"SELECT to_regclass('public.address')\"" 2>/dev/null | grep -q address; then
  count="$(su - postgres -c "psql -tAq -d kamailio -c 'SELECT COUNT(*) FROM address'" 2>/dev/null | tr -d ' ')"
  ok "Trunk address table present (${count:-0} entries)"
else
  warn "No address table - trunk-by-IP authentication will not work until the schema has one."
fi

kamailio -c -f /etc/kamailio/kamailio.cfg >/dev/null 2>&1 \
  || die "Kamailio config check failed. Run: kamailio -c -f /etc/kamailio/kamailio.cfg"
ok "Configuration syntax valid"

systemctl enable kamailio >/dev/null 2>&1 || true
restart_service kamailio

ok "Kamailio listening on ${SIP_PORT} (UDP/TCP)$( [ "$TLS_READY" = "1" ] && echo " and ${SIPS_PORT} (TLS)" )"
warn "The routing config is a safe baseline, not a finished dialplan."
warn "Number translation, outbound trunks and billing hooks still need to be added."
