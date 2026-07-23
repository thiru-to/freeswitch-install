# FreeSWITCH Installer for Debian/Ubuntu

A work-in-progress automation script for installing and running FreeSWITCH from source on Debian and Ubuntu servers.

This repository provides a simple bash-based installer that sets up a production-ready FreeSWITCH build, configures a systemd service, and prepares the environment needed to run the softswitch locally or on a server.

## Overview

The project currently focuses on one primary goal:

- automate the installation of FreeSWITCH from source
- build the required dependencies and modules
- install FreeSWITCH under /usr/local/freeswitch
- register it as a systemd service
- create the necessary system user and permissions

This repo is still evolving, and more features and refinements will be added over time.

## What the installer does

The current installer script performs the following steps:

1. Updates and upgrades the base system packages
2. Installs the required build and runtime dependencies
3. Clones the needed repositories for:
   - spandsp
   - libks
   - sofia-sip
   - FreeSWITCH
4. Builds and installs the supporting libraries
5. Configures FreeSWITCH module selection
6. Builds and installs FreeSWITCH to /usr/local/freeswitch
7. Installs FreeSWITCH sound packages
8. Creates the freeswitch system user and group, and adds the invoking user and any
   sudo-capable users to the freeswitch group
9. Installs a systemd service definition for FreeSWITCH

## Current supported environment

This installer is intended for:

- Debian or Ubuntu servers
- systems using systemd
- environments with sudo access
- fresh or lightly configured servers

It has been validated on Ubuntu 22.04 in a systemd-based environment.

## Requirements

Before running the installer, ensure that:

- the host is running Debian or Ubuntu
- you have sudo privileges
- the server has internet access to pull source code and packages
- systemd is available

## Usage

Run the installer directly from the repository root:

```bash
bash install.sh
```

You can optionally specify a FreeSWITCH tag to build:

```bash
bash install.sh v1.11.1
```

If you want to install it from a remote location, you can also clone the repo first and run the script locally.

## Project structure

```text
.
├── install.sh
├── README.md
├── resources/
│   └── freeswitch.service
└── CLAUDE.md
```

### Files

- install.sh: the main installer script
- resources/freeswitch.service: systemd service template used by the installer
- README.md: project overview and usage documentation
- CLAUDE.md: repository-specific guidance for contributors

## Notes

- The installer defaults to FreeSWITCH tag v1.11.1 if no tag is provided.
- The script is designed to be rerun safely after a partial failure.
- Some module selections are intentionally customized for this setup.
- Membership of the freeswitch group (which grants access to `conf/` and `log/` without
  sudo) only applies to new login sessions. Log out and back in after installing.

## Planned improvements

This repository is still in its early stages. Planned work may include:

- better configuration handling for different Ubuntu/Debian versions
- optional support for additional FreeSWITCH modules
- improved logging and install diagnostics
- documentation for post-install verification and troubleshooting
- support for more deployment scenarios and automation

## Contributing

Contributions are welcome as this project grows.

If you would like to improve the installer, add new features, or improve the documentation, feel free to open an issue or submit a pull request.

## License

This project is currently maintained as an open source installer script for FreeSWITCH deployment. Please check the repository for any license details before reusing it in production environments.
