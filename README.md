# VoIP PBX installer

Builds a production VoIP PBX on a fresh Debian 13 server: Kamailio as the public SIP edge,
FreeSWITCH as the media/PBX core behind it, rtpengine for media relay, PostgreSQL and Redis
for state, and a Bun/Hono API.

## Layout

```
install.sh              master installer - runs the steps in order
config.env.example      site configuration template
lib/common.sh           shared helpers (logging, idempotency, apt, files, services)
steps/                  the numbered step scripts
resources/              systemd unit templates
app/api/                the Hono API source
```

## Quick start

```bash
git clone https://github.com/thiru-to/freeswitch-install.git
cd freeswitch-install

# The first run creates /etc/voip-pbx/config.env and stops so you can fill it in.
sudo ./install.sh

sudo editor /etc/voip-pbx/config.env    # PBX_FQDN, LETSENCRYPT_EMAIL, ADMIN_ALLOW_CIDR
sudo ./install.sh
```

`PBX_FQDN` must already resolve to this server's public IP — Let's Encrypt validates over
HTTP, and `00-preflight.sh` warns if it does not.

## Usage

```bash
sudo ./install.sh                            # run everything still pending
sudo ./install.sh --list                     # show the plan and each step's state
sudo ./install.sh --only 30-freeswitch.sh    # run one step
sudo ./install.sh --from 40-bun.sh           # resume from a step
sudo ./install.sh --force                    # re-run everything
sudo ./install.sh --dry-run                  # show what would run
```

Re-running is safe. Each step records the SHA-256 of the script that satisfied it, so a
completed step is skipped **until that script changes** — edit a step and it re-runs by
itself. All output is logged to `/var/log/voip-install/`.

## Architecture

```text
                internet
                    |
            nftables (default deny)
                    |
    +---------------+----------------+
    |               |                |
 Kamailio        nginx           SSH (admin CIDR only)
 :5060/:5061     :443
    |               |
    |          Bun API :3000 (loopback)
    |               |
 rtpengine   PostgreSQL / Redis (loopback)
 RTP relay
    |
 FreeSWITCH :5080 (loopback)
```

Kamailio owns the public SIP ports and handles registration, authentication and flood
protection. FreeSWITCH never faces the internet — it listens on loopback and trusts only what
Kamailio forwards. rtpengine relays media, which is what makes calls work for clients on WiFi
and mobile behind NAT.

## Steps

| Step | Purpose |
|------|---------|
| `00-preflight` | Host validation, hostname, timezone, NTP, kernel/limit tuning |
| `01-base-packages` | Tooling, CA certificates, unattended security upgrades |
| `10-ssh-hardening` | Key-only SSH (refuses to lock you out if no key exists) |
| `11-firewall` | nftables default-deny with SIP rate limiting |
| `12-fail2ban` | Jails for sshd, FreeSWITCH and Kamailio |
| `13-tls-certs` | Let's Encrypt plus renewal hooks shared by all services |
| `20-postgresql` | PostgreSQL from PGDG, tuned to host memory |
| `21-redis` | Redis for mod_hiredis and API caching |
| `22-provision-databases` | Roles and databases, least privilege |
| `30-freeswitch` | FreeSWITCH from source |
| `31-freeswitch-config` | SIP profile, ACLs, ESL on loopback, Opus preference |
| `32-kamailio` | Kamailio from deb.kamailio.org |
| `33-kamailio-config` | Schema, TLS, registrar and routing |
| `34-rtpengine` | Media relay, kernel forwarding where available |
| `40-bun` | Bun runtime |
| `41-api-deploy` | API deploy, migrations, hardened systemd unit |
| `42-nginx` | TLS termination and reverse proxy |
| `50-logrotate` | Log retention |
| `51-backups` | Nightly database and config backups |
| `52-monitoring` | Health checks and node_exporter |
| `53-cron` | Scheduled maintenance |
| `99-postflight` | Verify the result; non-zero exit if unsound |

## After installing

`99-postflight.sh` lists what remains. In short:

- Create SIP subscribers: `kamctl add <user>@<domain> <password>`
- Write the dialplan and outbound trunk routing — `33-kamailio-config.sh` is a safe baseline,
  not a finished dialplan
- Narrow `ADMIN_ALLOW_CIDR` if it is still `0.0.0.0/0`
- Set `OFFSITE_RSYNC_TARGET` so backups leave the host
- Place a test call and confirm two-way audio

## Operations

```bash
voip-healthcheck                  # service, port, certificate and disk checks
voip-backup                       # run a backup now
fs_cli                            # FreeSWITCH console
kamctl ul show                    # current registrations
journalctl -u kamailio -f
```

## Secrets

Generated on first run and stored in `/etc/voip-pbx/config.env` (mode 0600). They are never
rotated by a re-run — that would break every service already holding the old value. Back this
file up: without it the database passwords are unrecoverable.

## Requirements

- Debian 13 (trixie) or Ubuntu, with systemd
- Root/sudo access and internet access
- A DNS record for `PBX_FQDN` pointing at the server
- ~2GB RAM and ~15GB free disk for the FreeSWITCH build plus sounds

## Notes

- Membership of the `freeswitch` group only applies to new login sessions — log out and back
  in after installing.
- Video is disabled (`--disable-libvpx`); this is a voice-only switch.
- Sound files are installed at 8kHz and 48kHz only. See `FS_SOUND_RATES`.
