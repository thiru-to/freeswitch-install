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
portal/api/             the Hono API source
portal/web/             the React admin portal
```

## Quick start

```bash
git clone https://github.com/thiru-to/freeswitch-install.git
cd freeswitch-install

# The first run creates /etc/voip-pbx/config.env and stops so you can fill it in.
# It exits 78 and tells you what to set - that is the expected first run, not a failure.
sudo ./install.sh

sudo editor /etc/voip-pbx/config.env    # PBX_FQDN, LETSENCRYPT_EMAIL, ADMIN_ALLOW_CIDR
sudo ./install.sh
```

`PBX_FQDN` must already resolve to this server's public IP — Let's Encrypt validates over
HTTP, and `00-preflight.sh` warns if it does not.

For a cloud instance, start at [Installing on a cloud server](#installing-on-a-cloud-server)
instead — the provider firewall has to be opened first or the install completes and no phone
can reach it.

## Installing on a cloud server

The same procedure works on Google Cloud, AWS and Vultr. Only two things differ between them:
how you create the instance, and where the inbound firewall lives.

### 1. What the server needs

| | |
|---|---|
| OS | Debian 13 (trixie). Ubuntu also works; nothing else is supported. |
| vCPU | 2 minimum. The FreeSWITCH build is the heavy part; call capacity needs far less. |
| RAM | 4 GB recommended, 2 GB is the floor (`00-preflight.sh` warns below ~1.8 GB). |
| Disk | 20 GB. The build plus sound files needs about 10 GB, and the rest is logs, recordings and voicemail. |
| Architecture | x86_64 or arm64. Both build; x86_64 is what this is verified on for production. |

A 2 vCPU / 4 GB instance handles a small business comfortably. The build takes roughly 10–20
minutes on 2 vCPU — that is the slow part of the install, not the configuration.

### 2. Open the ports in the provider firewall

**Do this before running the installer.** Every provider blocks inbound traffic by default
(Vultr is the exception — see below), and the installer's own nftables rules cannot open a port
the provider is already dropping.

| Port | Protocol | Source | What it is for |
|---|---|---|---|
| 22 | TCP | **your IP only** | SSH |
| 80 | TCP | 0.0.0.0/0 | Let's Encrypt HTTP-01 validation |
| 443 | TCP | 0.0.0.0/0 | Admin portal and API |
| 5060 | UDP **and** TCP | 0.0.0.0/0 | SIP signalling |
| 5061 | TCP | 0.0.0.0/0 | SIP over TLS |
| 8443 | TCP | 0.0.0.0/0 | SIP over secure WebSocket, for browser clients. Skip if `ENABLE_WEBRTC=0`. |
| 16384–32768 | UDP | 0.0.0.0/0 | RTP media, relayed by rtpengine |

Notes that matter:

- **The RTP range is genuinely that wide.** Media is relayed on both legs of every call
  (endpoint↔FreeSWITCH and FreeSWITCH↔carrier), so budget roughly 4 ports per concurrent call.
  Narrow it by setting `RTP_PORT_MIN`/`RTP_PORT_MAX` in the config *and* matching the provider
  rule to it — they must agree, or calls connect with no audio.
- **5060 needs both UDP and TCP.** Most SIP traffic is UDP; some endpoints and most carriers
  use TCP. Opening only one is a common cause of "some phones register and others do not".
- **Do not open 5070 or 5080.** Those are the internal Kamailio-egress and FreeSWITCH ports.
  They bind to loopback and must stay unreachable.
- Restrict 22 to your own address. `ADMIN_ALLOW_CIDR` in the config does the same thing at the
  host firewall; setting both is the point.

Port 5060 exposed to the internet is scanned within minutes. That is expected and handled —
nftables rate-limits SIP, fail2ban jails repeat offenders, and `14-responsive-firewall.sh`
tightens limits for sources that have never registered.

### 3a. Google Cloud Compute Engine

```bash
# Create the instance. Check the current image family first if this errors:
#   gcloud compute images list --project debian-cloud --filter="family~debian"
gcloud compute instances create pbx-1 \
  --machine-type=e2-standard-2 \
  --image-family=debian-13 --image-project=debian-cloud \
  --boot-disk-size=20GB --boot-disk-type=pd-balanced \
  --tags=voip-pbx \
  --zone=us-east1-b

# Reserve the address so it survives a stop/start, then note it for DNS.
gcloud compute addresses create pbx-1-ip --region=us-east1
gcloud compute instances describe pbx-1 --zone=us-east1-b \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

Firewall rules apply to the `voip-pbx` network tag:

```bash
gcloud compute firewall-rules create voip-pbx-web \
  --allow=tcp:80,tcp:443 --target-tags=voip-pbx --direction=INGRESS

gcloud compute firewall-rules create voip-pbx-sip \
  --allow=udp:5060,tcp:5060,tcp:5061,tcp:8443 --target-tags=voip-pbx --direction=INGRESS

gcloud compute firewall-rules create voip-pbx-rtp \
  --allow=udp:16384-32768 --target-tags=voip-pbx --direction=INGRESS

# SSH from your address only. Replace with your own /32.
gcloud compute firewall-rules create voip-pbx-ssh \
  --allow=tcp:22 --source-ranges=203.0.113.10/32 --target-tags=voip-pbx --direction=INGRESS
```

GCP gives the instance a private address on the NIC and maps the public IP with a 1:1 NAT.
That is handled — the installer detects it and configures Kamailio and rtpengine to advertise
the public address — but it is why `ip addr` on the server shows a 10.x address and nothing is
wrong.

### 3b. AWS EC2

```bash
# Find the current Debian 13 AMI for your region rather than hardcoding one.
aws ec2 describe-images --owners 136693071363 \
  --filters 'Name=name,Values=debian-13-amd64-*' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
```

```bash
# Security group
SG=$(aws ec2 create-security-group --group-name voip-pbx \
      --description "VoIP PBX" --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22   --cidr 203.0.113.10/32
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 80   --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 443  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol udp --port 5060 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 5060 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 5061 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol udp --port 16384-32768 --cidr 0.0.0.0/0

# Instance. t3.large is 2 vCPU / 8GB; t3.medium (2/4) also works.
aws ec2 run-instances --image-id <ami-from-above> --instance-type t3.large \
  --security-group-ids "$SG" --key-name <your-key> \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=pbx-1}]'
```

Then allocate an Elastic IP and associate it, so the address survives a stop/start:

```bash
EIP=$(aws ec2 allocate-address --query AllocationId --output text)
aws ec2 associate-address --instance-id <instance-id> --allocation-id "$EIP"
```

The default Debian user is `admin`, not `ubuntu` or `root`. Like GCP, EC2 uses 1:1 NAT — the
instance sees a private address and the installer handles the translation.

### 3c. Vultr Cloud Compute

Create the instance from the control panel or `vultr-cli`: Debian 13, at least 2 vCPU / 4 GB,
50 GB disk (Vultr's smaller plans include more disk than you need, which is fine).

Vultr differs from the other two in one important way: **the public IPv4 is assigned directly
to the instance's interface, and no cloud firewall is applied by default.** The server is
exposed to the internet from the moment it boots, so:

- Attach a Vultr Firewall Group with the ports from the table above, *or*
- Rely on the installer's nftables rules — but then run `11-firewall.sh` early, and set
  `ADMIN_ALLOW_CIDR` to your own address before you start.

Either way, do not leave the box reachable on every port while a 20-minute build runs.

Because there is no NAT, the installer will detect that the interface address and the public
address match and configure Kamailio and rtpengine without any translation. That is the
simpler case and needs nothing from you.

### 4. Point DNS at it

Create an **A record** for the name you will use as `PBX_FQDN`, pointing at the instance's
public IP, and wait for it to resolve:

```bash
dig +short pbx.example.com
```

This has to be right *before* the install reaches `13-tls-certs.sh`. Let's Encrypt validates
over HTTP against that name, and a certificate is needed for SIP TLS, WSS and the portal.

If the name is not ready yet, set `LETSENCRYPT_STAGING=1` in the config while testing so a
failed attempt does not burn the production rate limit.

### 5. Install

```bash
ssh admin@pbx.example.com          # 'admin' on AWS, your own user on GCP, 'root' on Vultr

sudo apt update && sudo apt install -y git
git clone https://github.com/thiru-to/freeswitch-install.git
cd freeswitch-install

# First run creates /etc/voip-pbx/config.env from the template and stops.
sudo ./install.sh

sudo editor /etc/voip-pbx/config.env
```

That first run ends with `>> Waiting for configuration.` and exit code 78. **That is the
expected first run, not a failure** — the installer has nothing to work with until you fill in
the file. A real failure looks different: it prints `XX Failed during: <step>` and points at
the log.

At minimum set:

```bash
PBX_FQDN="pbx.example.com"          # must already resolve to this server
PBX_SIP_DOMAIN="pbx.example.com"    # what endpoints put after the @
LETSENCRYPT_EMAIL="you@example.com"
ADMIN_ALLOW_CIDR="203.0.113.10/32"  # your address, not 0.0.0.0/0
TIMEZONE="America/Toronto"
```

Worth setting now rather than later:

```bash
SMTP_HOST="smtp.provider.example"   # voicemail-to-email and fax-to-email need a relay
SMTP_USER="..."
SMTP_PASSWORD="..."
SMTP_FROM="pbx@example.com"         # a domain you control, with SPF and DKIM
MAX_CONCURRENT_CALLS=10             # toll-fraud ceiling per tenant
```

Then run it:

```bash
sudo ./install.sh
```

It runs unattended from here — roughly 20–40 minutes, most of it compiling FreeSWITCH. Output
is logged to `/var/log/voip-install/`. If it stops, fix what it reports and run the same
command again; completed steps are skipped.

Leave `SMTP_HOST` empty if you have no relay yet. Voicemail and fax still work, they just do
not send email. Add it later with:

```bash
sudo editor /etc/voip-pbx/config.env
sudo ./install.sh --only 15-mail.sh --force
```

### 6. Check it came up

```bash
sudo voip-healthcheck
sudo ./install.sh --only 99-postflight.sh
```

`99-postflight.sh` exits non-zero if anything is unsound and prints what. Then confirm from
*outside* the server that the provider firewall is actually open:

```bash
# From your laptop, not the server.
nc -zv pbx.example.com 5060       # TCP SIP
nmap -sU -p 5060 pbx.example.com  # UDP SIP
curl -I https://pbx.example.com   # portal
```

A port that works on the server but not from outside is the provider firewall, not the
installer.

### 7. Create a tenant and an extension

Tenants are not self-served — a tenant owns a SIP domain, which is the isolation boundary, so
minting one is an operator action. The order matters:

**First**, open `https://pbx.example.com` and sign up. That creates the user account.

**Then** provision a tenant owned by that account, from the *deployed* API directory (it has
the environment file and dependencies; the git checkout does not):

```bash
cd /opt/voip-api
sudo -u voipapi bun run src/cli/provision-tenant.ts \
  --name "Acme Corp" \
  --slug acme \
  --domain pbx.example.com \
  --owner you@example.com
```

`--domain` is the SIP domain endpoints register against. It is unique platform-wide, and for a
single-tenant deployment it is normally the same as `PBX_SIP_DOMAIN`.

Sign in again, create an extension in the portal, and register a softphone with:

| | |
|---|---|
| Server / domain | your `PBX_SIP_DOMAIN` |
| Username | the extension number |
| Password | the SIP password shown **once** at creation |
| Transport | TLS on 5061 preferred; UDP on 5060 works |

Confirm the registration reached Kamailio:

```bash
kamctl ul show
```

### Cloud gotchas worth knowing

- **The public IP must be static.** A GCP ephemeral address or an EC2 instance without an
  Elastic IP changes on stop/start, which breaks DNS, the TLS certificate and every registered
  phone at once. Reserve the address.
- **Do not put a load balancer in front of SIP.** Cloud L4 balancers rewrite source addresses
  and do not understand SIP; registrations and in-dialog routing break in ways that look like
  random call failures. Kamailio is the load balancer in this design.
- **Symmetric NAT on the provider side is not a thing you can configure around.** All three
  providers do plain 1:1 NAT or none at all, which is why this works. Providers that do
  carrier-grade NAT are not usable for a SIP edge.
- **Egress matters as much as ingress.** If you tighten outbound rules, the server still needs
  to reach your carrier on 5060/5061 and the RTP range, plus 80/443 for packages and
  Let's Encrypt.
- **Check the SIP ports are not already claimed.** Some provider images ship with their own
  agents; `ss -lnup | grep 5060` before installing costs nothing.

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
 :5060/:5061     :443 (portal + API)
 :8443 (WSS)
    |               |
    |          Bun API :3000 (loopback)
    |               |
 rtpengine   PostgreSQL / Redis (loopback)
 RTP relay + WebRTC bridge
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
| `14-responsive-firewall` | Reputation-tiered SIP limits, learned from registrations |
| `15-mail` | Outbound SMTP relay for voicemail-to-email and fax-to-email |
| `20-postgresql` | PostgreSQL from PGDG, tuned to host memory |
| `21-redis` | Redis for mod_hiredis and API caching |
| `22-provision-databases` | Roles and databases, least privilege |
| `30-freeswitch` | FreeSWITCH from source |
| `31-freeswitch-config` | SIP profile, ACLs, ESL on loopback, Opus preference |
| `32-kamailio` | Kamailio from deb.kamailio.org |
| `33-stir-shaken` | STIR/SHAKEN caller attestation (source build, off by default) |
| `34-kamailio-config` | Schema, TLS, registrar, routing, WebRTC/WSS |
| `35-rtpengine` | Media relay, WebRTC bridging, kernel forwarding |
| `40-bun` | Bun runtime |
| `41-api-deploy` | API deploy, migrations, hardened systemd unit |
| `42-nginx` | TLS termination and reverse proxy |
| `43-portal-web` | Build the React admin portal and publish it |
| `50-logrotate` | Log retention |
| `51-backups` | Nightly database and config backups |
| `52-monitoring` | Health checks and node_exporter |
| `53-cron` | Scheduled maintenance |
| `99-postflight` | Verify the result; non-zero exit if unsound |

## After installing

`99-postflight.sh` lists what remains. In short:

- Sign up in the portal, then provision a tenant with `provision-tenant.ts` — see
  [step 7](#7-create-a-tenant-and-an-extension)
- Create extensions **in the portal**, not with `kamctl add`. The API writes Kamailio's
  `subscriber` table itself, as an HA1 digest; a subscriber added by hand registers fine but is
  invisible to the portal and gets no dialplan, voicemail or CDR
- Add a trunk and outbound routes so calls can leave. Number translation and least-cost routing
  are business logic and are deliberately absent
- Narrow `ADMIN_ALLOW_CIDR` if it is still `0.0.0.0/0`
- Set `OFFSITE_RSYNC_TARGET` so backups leave the host
- Place a test call and confirm two-way audio in both directions

## Operations

```bash
sudo voip-healthcheck             # service, port, certificate and disk checks
sudo voip-backup                  # run a backup now
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
- 2 vCPU, 4 GB RAM and 20 GB disk recommended; the installer warns below ~1.8 GB RAM or 15 GB
  free, which is roughly what the FreeSWITCH build plus sound files needs
- On a cloud provider, the inbound ports opened in the provider firewall — see
  [Installing on a cloud server](#installing-on-a-cloud-server)

## Notes

- Membership of the `freeswitch` group only applies to new login sessions — log out and back
  in after installing.
- Video is disabled (`--disable-libvpx`); this is a voice-only switch.
- WebRTC is on by default (`ENABLE_WEBRTC=1`, WSS on 8443). rtpengine bridges DTLS-SRTP to
  plain RTP, so FreeSWITCH needs no WebRTC support of its own and mod_verto stays disabled.
- STIR/SHAKEN is off by default. It is a source build (neither libstirshaken nor Kamailio's
  stirshaken module is packaged for Debian) and needs a certificate from an STI-CA.
- Sound files are installed at 8kHz and 48kHz only. See `FS_SOUND_RATES`.
