# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An installer for a full VoIP PBX stack on Debian 13: Kamailio (public SIP edge) in front of FreeSWITCH (media/PBX core), with rtpengine, PostgreSQL, Redis and a Bun/Hono API. There is no test suite — it is bash plus the assets it deploys.

- `install.sh` — master installer. Runs `steps/*.sh` in order. Idempotent: each step's marker in `/var/lib/voip-install/` holds the SHA-256 of the script that satisfied it, so a step re-runs automatically when its script changes. Flags: `--list`, `--only`, `--from`, `--force`, `--dry-run`. Logs to `/var/log/voip-install/`.
- `lib/common.sh` — shared helpers, sourced by every step. `apt_install` only installs what is missing; `write_file` writes from stdin and returns 1 when the content was already correct (so callers can skip a reload); `config_ensure_secret` generates a secret once and persists it.
- `config.env.example` → `/etc/voip-pbx/config.env` (0600). Site config plus generated secrets. **Never rotate a secret on re-run** — every service already holds the old value.
- `steps/` — the numbered step scripts. The number encodes ordering; dependencies flow downwards.
- `resources/freeswitch.service` — systemd unit template. `${PREFIX}` is substituted by sed at deploy time (systemd does not expand shell variables), so keep the placeholder intact.
- `resources/lua/` — the call-time scripts, deployed by `31-freeswitch-config.sh`. This is the code that runs while a call is being set up; see "Call-time resolution" below.
- `portal/api/` — Bun/Hono API. Owns every write: Postgres, the Redis cache, and Kamailio's `subscriber`/`domain` tables. Also holds the operator CLIs in `src/cli/`.
- `portal/web/` — React admin portal (Vite, TanStack Router, React Query, Mantine). Built and published by `43-portal-web.sh`.

Steps read their configuration from `/etc/voip-pbx/config.env` via `load_config`, and reference repo files through `$REPO_DIR` (set by `lib/common.sh`). Earlier versions cloned this repo onto the target to find `resources/`, which meant a local edit did nothing until pushed — that is gone; the local checkout is used directly.

### Topology this assumes

Kamailio owns the public SIP ports (5060/5061) and does registration, auth and flood control. FreeSWITCH listens only on `127.0.0.1:5080` and trusts what Kamailio forwards (`auth-calls=false` paired with a loopback-only ACL — the pairing is what makes it safe, so do not change one without the other). rtpengine relays all media; FreeSWITCH NAT handling is deliberately off so the two do not both rewrite SDP.

## The recurring failure mode here — read this before adding a check

The same bug has been found in this codebase five separate times: **elaborate, well-commented configuration wired to nothing.** The RBAC role model guarded 2 of ~30 routes; role resolution read a session field that does not exist, so every user was a `member` and a `viewer` could delete extensions; the `apiKey` plugin was unused, broken and live on an internet-facing path; `sendInvitationEmail` was an empty function whose comment described a link that did not exist; a `pg_query_one` helper made a Lua fallback tier look present when nothing called it.

Detailed comments are what makes this hard to see — the prose describes intent so convincingly that the absent enforcement reads as present. So:

- **Make the check structural, not remembered.** `permission` is a *required* option on `crudRoutes` (`portal/api/src/lib/crud.ts`) precisely so a new resource cannot be added without one. Prefer that shape over "remember to add the middleware".
- **Prove a control works by trying to break it.** Every one of the above passed typecheck, lint and build. Sign in as the low-privilege role and attempt the thing it must not do; then re-run the identical sequence after the fix.
- Sub-path routes (`/:id/members`, `/:id/options`, `/:id/password`) are separate Hono apps mounted onto the parent, so they do **not** inherit its `crudRoutes` gate. Each mounts its own `requireTenant` + `requirePermission` — check for both when touching them.

## The portal (portal/api, portal/web)

- **A tenant IS a better-auth organization.** `session.activeOrganizationId` is the scope for every request. `requireTenant` (`portal/api/src/middleware/tenant.ts`) refuses to proceed without one rather than defaulting to "all" — an unscoped query here is a data breach, not a bug. This is the isolation boundary; the plan chose API-layer enforcement over Postgres RLS because the API is the only writer.
- **The role comes from the `member` row, re-read on every request** — not from the session. Two reasons, both bugs that happened: `session.activeOrganizationRole` does not exist (so the `?? "member"` fallback fired every time), and `activeOrganizationId` is copied into the session at set-active time, so a removed member kept full access for up to eight hours. One indexed lookup on `(user_id, organization_id)`.
- Roles are defined once in `portal/api/src/auth.ts` via `createAccessControl`, exported as `ROLES`, and enforced by `requirePermission` calling `.authorize()`. Add a permission to the statement, not to a hard-coded role list. An unknown role is refused, never defaulted.
- **No self-service registration**, by design — a portal account administers telephony, so a compromise is toll fraud on a customer's bill. Three layers: nginx 404s `^/api/auth/sign-up`, a `databaseHooks.user.create.before` hook throws unless an in-process flag is set, and `src/cli/create-user.ts` sets that flag. `emailAndPassword.disableSignUp` is **not** usable here — better-auth enforces it in the same handler `auth.api.signUpEmail()` calls, so it would block the CLI too.
- There is **no default admin account and no seeding step.** The operator runs `create-user.ts` then `provision-tenant.ts` on the server. Adding a second user to an existing tenant has no CLI yet: `provision-tenant.ts` stops once the organization has any member.
- `42-nginx.sh` gates the SPA with `auth_request` against `GET /internal/session` (200/401, fails closed). Two things there are load-bearing: **`location = /` must exist as an exact match** or the site root falls into the gated prefix and an anonymous visitor 404s at `/` with no way to reach the login page; and `/assets/` must stay public or the login page cannot load its own bundle. The second is an accepted limitation, documented in the README — route names stay readable.
- better-auth reads the client address from **`x-real-ip`, not `x-forwarded-for`**. nginx builds XFF with `$proxy_add_x_forwarded_for`, which appends to whatever the client sent, so a client can prepend a fake address and be rate-limited as that. Without a usable header better-auth falls back to one shared bucket per path, which is worse than no limiter: one attacker locks out every user.
- Postgres has both databases: `kamailio` and `voipapi` (that is the API's, despite the repo name). The systemd unit is `voip-api`, the service account `voipapi`, the deploy directory `/opt/voip-api`. CLIs must be run from there, not the git checkout — the checkout has neither `.env` nor dependencies.
- React Query v5 tracks which result properties a component reads, so **passing a whole `useQuery` result down to a child breaks the subscription.** Destructure at the call site and pass the fields (`QueryState` in `components/Resource.tsx` takes them separately, with a comment saying why). Also check `isEmpty` against `isSuccess`, not just an empty array — a failed fetch otherwise renders "No trunks yet".
- `bun install` fails for an unprivileged user against a root-owned bun cache. Use `bun_as` from `lib/common.sh`.

## Call-time resolution (resources/lua)

`31-freeswitch-config.sh` binds `mod_lua` as the primary XML handler and `mod_xml_curl` second; bindings fall through, so declining in Lua is how a request reaches the API. Two tiers on purpose:

1. `xml_handler.lua` answers from Redis, reached through `mod_hiredis`. The API writes those keys; Lua only ever reads them. Key shapes are contractual — they are listed in `portal/api/src/services/redis.ts`, and changing one means changing both sides.
2. `mod_xml_curl` → the API → Postgres, for anything the cache does not hold.

- **There is deliberately no Postgres tier in Lua.** It was planned, half-written (`pg_query_one`), never called, and has been removed. Do not reintroduce it: it would mean reimplementing DID, feature-number and outbound-route resolution in a second language, and the case it was for (cold cache) is now handled by the API's warm watchdog.
- Redis is a **pure cache** (`save ""`, `appendonly no`), so a restart empties it — and `unattended-upgrades` will do that at night. `index.ts` polls a `voip:warm` sentinel every 60s and rebuilds when it is gone; `claimWarm()` uses `SET NX` so multiple API instances produce one rebuild. Without this, every call setup took the HTTP path indefinitely and the tier meant to survive an API outage was silently off.
- `rebuildTenant` purges before repopulating, using the **enumerated** patterns in `keys.tenantPatterns` rather than `voip:*:<domain>*` — the trailing wildcard would also match a tenant whose domain merely starts with this one. A new key shape must be added there or it survives a rebuild as a ghost.
- **When testing anything the XML handler produces, run `fs_cli -x xml_flush_cache` between phases.** FreeSWITCH's own directory cache will serve the previous answer and turn a real failure into a passing test — this produced a false positive during the cache-resilience work.
- `strftime_tz`'s format string must not contain `|` — it is parsed as an epoch delimiter. `time_condition.lua` uses commas.
- A time-condition rule with `invert` must **break** the loop when it matches. Continuing lets a later matching rule overwrite the exclusion, which silently re-opens a holiday.
- The `limit` *application* hangs up on exceed, so it cannot be used to detect call waiting — an answered call is a billed call. Read the count with the `limit_usage` API, decide, then increment with a bare `limit`.
- Feature codes are matched **before** the directory so a tenant cannot shadow one with an extension, and the subject is the authenticated user from `X-Auth-User`, never `From:`. Escape codes before using them as patterns — `^*97$` is invalid PCRE (`regex_escape` in `xml_handler.lua`).
- Internally dialled feature numbers (600 for a ring group, 700 for the attendant) need the `voip:num:` index, checked after the directory. Without it a dialled 600 is neither an extension nor a DID and dies as `UNALLOCATED_NUMBER`.

## Validating changes

Static checks first — but do not stop there. `bash -n` and `shellcheck` both pass clean on scripts that fail several different ways at runtime:

```sh
bash -n install.sh
shellcheck install.sh

# Portal, when it was touched. TanStack's route tree is generated, so typecheck regenerates it.
cd portal/api && bun run typecheck
cd portal/web && bun run typecheck && bun run lint && bun run build
```

Real verification is an end-to-end run in a Debian 13 systemd container (~2 min on 12 cores). This is the only thing that catches missing dev libraries, modules that fail to load at boot, and service start-up problems.

```sh
# Image: debian:13 + systemd systemd-sysv sudo ca-certificates git procps, CMD ["/sbin/init"]
docker run -d --name fs-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock <image>

# Seed the clone so the run tests LOCAL changes: clone from GitHub into
# /usr/src/freeswitch-install, copy the working tree over it, then commit. Being one commit
# ahead makes the script's `git pull --ff-only` a no-op ("Already up to date") instead of
# reverting the changes under test.

docker exec -d fs-test bash -c '/root/install.sh >/var/log/fs.log 2>&1; echo $? >/var/log/fs.exit'
```

Assertions worth making afterwards — each of these has caught a real bug:

- exit code is 0 and `$PREFIX/bin/freeswitch` exists
- every `FS_ENABLE_MODULES` entry is present in `$PREFIX/mod/`, every `FS_DISABLE_MODULES` entry is absent
- `systemctl is-active freeswitch`, and `$PREFIX/run/freeswitch.pid` matches `systemctl show freeswitch -p MainPID`
- `fs_cli -x status` responds, and `fs_cli -x "show codec"` lists Opus
- **zero `[ERR]`/`[CRIT]` in `$PREFIX/log/freeswitch.log`** — a successful build does not imply a clean boot
- re-running the script over the finished install exits 0 again (it is meant to be idempotent)

For portal changes, in the same container:

- anonymous: `/` is the login page, the app routes 404, `/api/*` 401, `/health` returns **JSON not HTML**, `POST /api/auth/sign-up/email` 404
- signed in: a deep-link refresh on `/trunks` returns the app rather than 404 — the whole `auth_request` design exists to make that hold
- **a low-privilege role is refused what it must not do.** Sign in as `viewer` and attempt a trunk create; a `400` for a missing field means the gate passed and validation ran, a `200` means it did not
- CLIs run from the deployed directory: `cd /opt/voip-api && sudo -u voipapi bun run src/cli/create-user.ts ...`

Copying the working tree into the container with `tar` **does not delete files that moved** — a stale route file left behind by a rename will keep being served and looks like a product bug. Remove the target directory first when route files have moved.

**Architecture caveat — this has already caused a production failure.** On Apple Silicon the container is arm64; the servers are x86_64 (Google Cloud C4). An arm64 pass is not a general pass. The concrete case: libvpx needs an external assembler (yasm/nasm) for its SSE/AVX paths on x86_64, but uses NEON intrinsics via gcc on arm64 and never asks — so a missing assembler is *completely invisible* on arm64 and fails the build on a real server. Any change touching apt dependencies or `./configure` flags should be re-run on amd64:

```sh
docker run -d --platform linux/amd64 ... # same recipe, ~5x slower under emulation
```

Known limitation of the emulated amd64 container: **its systemd is broken** — journald, sysusers, sysctl and tmp.mount all fail, and `systemd-run /bin/sleep 300` fails too. So an amd64 run verifies the *build* (dependencies, configure flags, modules) but cannot verify the service. Start FreeSWITCH manually there (`sudo -u freeswitch $PREFIX/bin/freeswitch -ncwait -nonat`) to check runtime behaviour, and rely on the arm64 container for the systemd unit. Kill leftover instances between manual runs or the log fills with spurious `Could not listen` / `Error Creating SIP UA` port conflicts.

## Things to know when editing the step scripts

- Adding a step means adding it to the `STEPS` array in `install.sh` *and* creating `steps/<name>`. A step listed with no file warns and is skipped rather than failing the run, so the installer stays usable while the set is incomplete.
- Steps must be safe to re-run. Use the `lib/common.sh` helpers rather than raw `apt-get` / `cat >` — that is what makes a second run quiet instead of noisy and destructive.
- **Do not lock "other" out of `/usr/local/freeswitch`.** Anyone with sudo can read it anyway, so `o-rwx` adds no protection and only breaks routine inspection (this was a real bug: admins got permission denied everywhere). Writes are restricted through the `freeswitch` group; config dirs are setgid so admin-created files stay group-readable by the service.
- `31-freeswitch-config.sh` binds ESL to `127.0.0.1` with a generated password. The stock config listens on `::`, which fails outright on IPv6-less hosts and is far too open where it does work.
- `34-kamailio-config.sh` (33 is STIR/SHAKEN) writes a deliberately conservative routing config — register, authenticate, protect, relay. Number translation, outbound trunking and billing are business logic and are intentionally absent.
- Kamailio needs a per-listener `advertise` on any host behind 1:1 NAT (GCP, EC2), or SIP breaks entirely — the interface holds a 10.x address while endpoints must be told the public one. Global `advertised_address` is not enough. `acc`/`missed_calls` `db_extra` columns need explicit ALTERs, outside the schema-creation guard, or accounting fails on every call.
- Do not `git add -A` in this repo: it sweeps `.claude/` and local MCP config into the commit. Stage paths explicitly.

## Modules and dependencies (30-freeswitch.sh)

- The module selection (`FS_ENABLE_MODULES` / `FS_DISABLE_MODULES`) is the intent-carrying part of the script: it enables mod_callcenter, mod_cidlookup, mod_hiredis, mod_curl, mod_shout, mod_pgsql, mod_easyroute, mod_nibblebill, mod_fail2ban, mod_xml_curl and disables mod_skinny, mod_verto, mod_say_es, mod_say_fr, mod_av, mod_xml_rpc, mod_signalwire. Preserve this set unless asked to change it. Do not re-enable mod_v8 — it needs libv8-6.1-dev, gone from modern Ubuntu/Debian.
- Caching is Redis, via mod_hiredis. mod_memcache was deliberately removed (2026-07-29) — do not reintroduce it or `libmemcached-dev`.
- **This is a voice-only switch: video is off via `--disable-libvpx`.** FreeSWITCH otherwise builds `libs/libvpx` unconditionally (`enable_libvpx="yes"`), and on x86_64 that needs yasm/nasm. Disabling it is preferred over adding those assemblers — VP8/VP9 are dead weight here. It is safe: the core gates video on `SWITCH_HAVE_VPX`, mod_av is disabled, and mod_video_filter is off by default. If you ever re-enable video you must add `nasm yasm` to the apt list or x86_64 builds fail.
- Every enabled module needs its dev library in the apt list or the build dies mid-`make` (mod_hiredis → libhiredis-dev, mod_shout → libshout3-dev/libmpg123-dev/libmp3lame-dev). The module-path guard does **not** catch a missing dev lib — only a real build does. That is how the mod_memcache/libmemcached-dev mismatch surfaced.
- v1.11.1's `configure.ac` needs PCRE2 only (`PKG_CHECK_MODULES([PCRE2], [libpcre2-8 >= 10.00])`). `libpcre3-dev` is not required and was dropped deliberately — it is also gone from Debian 13, where it would fail the whole apt transaction.
- Module paths must match `build/modules.conf.in` exactly or the `sed` silently no-ops and the module keeps its default state. The non-obvious ones: `databases/mod_pgsql` (not formats/) and `say/mod_say_es` + `say/mod_say_fr` (not applications/). The script greps each entry first and aborts if a path moved upstream — keep that guard.

## The minimal config

- `make install` only lays down a config if `$PREFIX/conf` is absent, and it installs **vanilla** (`install-data-local` → `samples-conf` → `config-vanilla`). There is no `$PREFIX/conf/minimal` to copy from. Use `rm -rf $PREFIX/conf` then `make config-minimal` — the `config-%` rule skips files that already exist, so the old tree must go first.
- Disabling a module in `modules.conf` is only half the job: the minimal config's `autoload_configs/modules.conf.xml` still lists it (e.g. `mod_xml_rpc`), so FreeSWITCH logs `[CRIT] Error Loading module` on every start. The script comments out any autoloaded module that was not built — keep the two lists in sync.
- The "Codec Interfaces" section is **empty**, so only the core G.711 (PCMU/PCMA) codecs exist at runtime. `mod_opus` is enabled in stock `modules.conf` and builds fine but is never loaded unless explicitly added — that is what `FS_AUTOLOAD_ADD` does. Opus matters here because calls run over WiFi.
- A module autoloaded into the minimal config also needs its `<mod>.conf.xml`, which only ships in the vanilla tree. Without `opus.conf.xml`, mod_opus logs `Opening of opus.conf failed` and falls back to built-in defaults — losing `keep-fec-enabled`, the thing that makes Opus tolerate WiFi packet loss. The script copies the vanilla config for each autoloaded module.
- The stock event_socket config listens on `::`; on IPv6-less hosts (some Docker setups) mod_event_socket fails to bind until listen-ip is changed to 127.0.0.1.

## Service and permissions

- The unit runs as `User=freeswitch`, which needs write access to `$PREFIX/{db,log,run,recordings}` — so `chown -R freeswitch:freeswitch $PREFIX` is required, not a chown of some copy under `/etc`. FreeSWITCH reads `$PREFIX/conf`, never `/etc/freeswitch`, unless passed `-conf`; `/etc/freeswitch` is only a convenience symlink.
- `Type=forking` (FreeSWITCH daemonises under `-ncwait`) needs `PIDFile=${PREFIX}/run/freeswitch.pid` or systemd guesses the main PID.
- `ExecStop=${PREFIX}/bin/freeswitch -stop` (with `TimeoutStopSec`) lets FreeSWITCH tear down channels and flush CDRs instead of being SIGTERMed.

## Sounds

- Never use the `hd-`/`uhd-`/`cd-` targets. They chain downwards (`cd-sounds-install` → `uhd-` → `hd-` → 8k), so asking for 48k silently downloads all four rates (~383MB). Use the per-rate targets (`sounds-en-us-callie-48000-install`), which the Makefile's `.DEFAULT` rule resolves to a single tarball.
- `FS_SOUND_RATES` controls the set. 8000 (G.711/PSTN legs) + 48000 (Opus) is ~202MB; 8k-only prompts get upsampled for Opus callers and sound muffled.

## Build ordering and environment

- spandsp, libks and sofia-sip must be built and installed (plus `ldconfig`) before FreeSWITCH's `./configure`. The script uses `set -euo pipefail`, and the clone/user-creation steps are guarded so re-running after a failure resumes cleanly.
- The `adduser` flags are chosen for Ubuntu 22.04's older adduser: use `--gecos` (not `--comment`) and keep the username last.
- Last verified 2026-07-29 on Debian 13.6 / systemd 257, tag v1.11.1, both architectures:
  - **arm64 (native)** — exits 0 in ~120s, intended modules built and excluded ones absent, only the 8000/48000 sound rates present, mod_opus loaded and listed by `show codec`, `make` never enters `libs/libvpx`, service active with MainPID matching the pidfile, zero `[ERR]`/`[CRIT]`, clean stop/start, and a second run over the finished install exits 0 (~30s).
  - **x86_64 (emulated)** — full build succeeds in ~670s with no yasm/nasm error and libvpx never entered; started manually, FreeSWITCH reports ready with Opus present and no VP8/VP9/H264. The service could not be verified here (broken systemd in the emulated container, see above).
  - Not verified on Ubuntu 22.04 since these changes.
- Portal auth verified 2026-07-30 in the arm64 container: anonymous 404s on app routes with the login page at `/`, deep-link refresh works signed in, a `viewer` is refused trunk writes, and a hand-inserted `admin` member row grants them. `15-mail.sh` added `msmtp`/`msmtp-mta` to the apt set **after** the last amd64 pass, so that run is still owed.
