# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An installer for a full VoIP PBX stack on Debian 13: Kamailio (public SIP edge) in front of FreeSWITCH (media/PBX core), with rtpengine, PostgreSQL, Redis and a Bun/Hono API. There is no test suite — it is bash plus the assets it deploys.

- `install.sh` — master installer. Runs `steps/*.sh` in order. Idempotent: each step's marker in `/var/lib/voip-install/` holds the SHA-256 of the script that satisfied it, so a step re-runs automatically when its script changes. Flags: `--list`, `--only`, `--from`, `--force`, `--dry-run`. Logs to `/var/log/voip-install/`.
- `lib/common.sh` — shared helpers, sourced by every step. `apt_install` only installs what is missing; `write_file` writes from stdin and returns 1 when the content was already correct (so callers can skip a reload); `config_ensure_secret` generates a secret once and persists it.
- `config.env.example` → `/etc/voip-pbx/config.env` (0600). Site config plus generated secrets. **Never rotate a secret on re-run** — every service already holds the old value.
- `steps/` — the numbered step scripts. The number encodes ordering; dependencies flow downwards.
- `resources/freeswitch.service` — systemd unit template. `${PREFIX}` is substituted by sed at deploy time (systemd does not expand shell variables), so keep the placeholder intact.

Steps read their configuration from `/etc/voip-pbx/config.env` via `load_config`, and reference repo files through `$REPO_DIR` (set by `lib/common.sh`). Earlier versions cloned this repo onto the target to find `resources/`, which meant a local edit did nothing until pushed — that is gone; the local checkout is used directly.

### Topology this assumes

Kamailio owns the public SIP ports (5060/5061) and does registration, auth and flood control. FreeSWITCH listens only on `127.0.0.1:5080` and trusts what Kamailio forwards (`auth-calls=false` paired with a loopback-only ACL — the pairing is what makes it safe, so do not change one without the other). rtpengine relays all media; FreeSWITCH NAT handling is deliberately off so the two do not both rewrite SDP.

## Validating changes

Static checks first — but do not stop there. `bash -n` and `shellcheck` both pass clean on scripts that fail several different ways at runtime:

```sh
bash -n install.sh
shellcheck install.sh
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
- `33-kamailio-config.sh` writes a deliberately conservative routing config — register, authenticate, protect, relay. Number translation, outbound trunking and billing are business logic and are intentionally absent.

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
