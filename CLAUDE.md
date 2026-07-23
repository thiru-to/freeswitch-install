# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A FreeSWITCH source-build installer for Debian/Ubuntu servers. There is no application code, build system, or test suite — just a bash script and the assets it deploys:

- `install.sh` — the entire installer. Takes an optional FreeSWITCH git tag as `$1` (defaults to `v1.10.13`). It installs apt dependencies, clones and builds spandsp, libks, sofia-sip, and FreeSWITCH under `/usr/src`, edits FreeSWITCH's `modules.conf` to enable/disable specific modules, installs to `/usr/local/freeswitch`, creates the `freeswitch` user/group, and installs a systemd unit.
- `resources/freeswitch.service` — systemd unit copied to `/etc/systemd/system/`. Note it references `${PREFIX}` literally; systemd does not expand shell variables, so the paths must be substituted (or hardcoded) when the file is deployed. It is also missing its `[Unit]` section header (line 1 starts with `Description=`).

The script clones `https://github.com/thiru-to/freeswitch-install.git` onto the target machine to obtain `resources/` — so changes here must be pushed before they affect a server install.

## Validating changes

The script targets a Linux server and cannot be run on this macOS machine. Check changes with:

```sh
bash -n install.sh        # syntax check
shellcheck install.sh     # lint, if installed
systemd-analyze verify    # only on a Linux host, for the unit file
```

## Things to know when editing install.sh

- The module selection (the block of `sed` edits on `modules.conf`) is the intent-carrying part of the script: it enables mod_callcenter, mod_cidlookup, mod_memcache, mod_hiredis, mod_curl, mod_shout, mod_pgsql, mod_easyroute, mod_nibblebill, mod_fail2ban, mod_xml_curl, mod_v8 and disables mod_skinny, mod_verto, mod_say_es, mod_say_fr, mod_av, mod_xml_rpc, mod_signalwire. Preserve this set unless asked to change it.
- The script has no shebang and no `set -e`; each step runs regardless of prior failures. Ordering matters: spandsp, libks, and sofia-sip must be built and installed before FreeSWITCH's `./configure`.
- Known defects (as of the current version) if asked to harden the script: clones run in the invoking directory rather than `$BUILD_DIR`; line 83 passes `./configure` to itself as an argument; the `sudo cat ... > /etc/systemd/system/...` redirect runs unprivileged; `$FS_VERSION` is defined but never used in the clone step.
