# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A FreeSWITCH source-build installer for Debian/Ubuntu servers. There is no application code, build system, or test suite — just a bash script and the assets it deploys:

- `install.sh` — the entire installer. Takes an optional FreeSWITCH git tag as `$1` (defaults to `v1.11.1`; the tag must exist in signalwire/freeswitch — check with `git ls-remote --tags`). It installs apt dependencies, clones and builds spandsp, libks, sofia-sip and FreeSWITCH under `/usr/src`, selects modules, installs to `/usr/local/freeswitch`, swaps in the minimal config, creates the `freeswitch` user/group, and installs a systemd unit.
- `resources/freeswitch.service` — systemd unit template. The script substitutes the literal `${PREFIX}` placeholder with sed when deploying it (systemd does not expand shell variables), so keep the placeholder intact in the repo copy.

**Changes must be pushed to `main` before they affect a server install.** The script clones `https://github.com/thiru-to/freeswitch-install.git` on the target machine to obtain `resources/`, and on re-runs does `git pull --ff-only` on that clone. A local edit that has not been pushed will not be used.

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

Caveat: on Apple Silicon this exercises arm64, not the x86_64 the servers run.

## Modules and dependencies

- The module selection (`FS_ENABLE_MODULES` / `FS_DISABLE_MODULES`) is the intent-carrying part of the script: it enables mod_callcenter, mod_cidlookup, mod_hiredis, mod_curl, mod_shout, mod_pgsql, mod_easyroute, mod_nibblebill, mod_fail2ban, mod_xml_curl and disables mod_skinny, mod_verto, mod_say_es, mod_say_fr, mod_av, mod_xml_rpc, mod_signalwire. Preserve this set unless asked to change it. Do not re-enable mod_v8 — it needs libv8-6.1-dev, gone from modern Ubuntu/Debian.
- Caching is Redis, via mod_hiredis. mod_memcache was deliberately removed (2026-07-29) — do not reintroduce it or `libmemcached-dev`.
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
- Last verified end-to-end on 2026-07-29: fresh Debian 13.6 / systemd 257 (privileged container, arm64), tag v1.11.1 — exits 0 in ~120s, intended modules built and excluded ones absent, only the 8000/48000 sound rates present, mod_opus loaded and listed by `show codec`, service active with MainPID matching the pidfile, zero `[ERR]`/`[CRIT]`, clean stop/start cycle, and a second run over the finished install exits 0 (~30s). Not re-verified on x86_64 or Ubuntu 22.04 since these changes.
