# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A FreeSWITCH source-build installer for Debian/Ubuntu servers. There is no application code, build system, or test suite — just a bash script and the assets it deploys:

- `install.sh` — the entire installer. Takes an optional FreeSWITCH git tag as `$1` (defaults to `v1.11.1`; the tag must exist in signalwire/freeswitch — check with `git ls-remote --tags`). It installs apt dependencies, clones and builds spandsp, libks, sofia-sip, and FreeSWITCH under `/usr/src`, edits FreeSWITCH's `modules.conf` to enable/disable specific modules, installs to `/usr/local/freeswitch`, creates the `freeswitch` user/group, and installs a systemd unit.
- `resources/freeswitch.service` — systemd unit template. The script substitutes the literal `${PREFIX}` placeholder with sed when deploying it (systemd does not expand shell variables), so keep the placeholder intact in the repo copy.

The script clones `https://github.com/thiru-to/freeswitch-install.git` onto the target machine to obtain `resources/` — so changes here must be pushed before they affect a server install.

## Validating changes

The script targets a Linux server and cannot be run on this macOS machine. Check changes with:

```sh
bash -n install.sh        # syntax check
shellcheck install.sh     # lint, if installed
systemd-analyze verify    # only on a Linux host, for the unit file
```

## Things to know when editing install.sh

- The module selection (the block of `sed` edits on `modules.conf`) is the intent-carrying part of the script: it enables mod_callcenter, mod_cidlookup, mod_memcache, mod_hiredis, mod_curl, mod_shout, mod_pgsql, mod_easyroute, mod_nibblebill, mod_fail2ban, mod_xml_curl and disables mod_skinny, mod_verto, mod_say_es, mod_say_fr, mod_av, mod_xml_rpc, mod_signalwire. Preserve this set unless asked to change it. Do not re-enable mod_v8 — it requires libv8-6.1-dev, which no longer exists on modern Ubuntu/Debian.
- Every module enabled in `modules.conf` needs its dev library in the apt dependency list or the build fails mid-make (e.g. mod_hiredis → libhiredis-dev, mod_memcache → libmemcached-dev, mod_shout → libshout3-dev/libmpg123-dev/libmp3lame-dev). FreeSWITCH 1.10/1.11 also requires PCRE1 (`libpcre3-dev`), not just PCRE2.
- Ordering matters: spandsp, libks, and sofia-sip must be built and installed (plus `ldconfig`) before FreeSWITCH's `./configure`. The script uses `set -euo pipefail`, and the clone/user-creation steps are guarded so re-running after a failure resumes cleanly.
- The `adduser` flags are chosen to work on Ubuntu 22.04's older adduser: use `--gecos` (not `--comment`) and keep the username as the last argument.
- Last verified end-to-end on 2026-07-23: fresh Ubuntu 22.04 (systemd container), tag v1.11.1 — script exits 0, freeswitch.service active, fs_cli responds, intended modules built. Note the stock event_socket config listens on `::`; on IPv6-less hosts (e.g. Docker) mod_event_socket fails to bind until listen-ip is changed to 127.0.0.1.
