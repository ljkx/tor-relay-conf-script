# Changelog

All notable changes to this project are documented here.

## v1.0.0-beta.2 - 2026-05-18

### Fixed

- Lock acquisition now falls back to `/tmp/tor-relay-setup.lock` when `/run/lock/tor-relay-setup.lock` cannot be opened on a VPS.

## v1.0.0-beta.1 - 2026-05-18

First public beta release.

### Added

- Interactive Guard/middle and exit relay setup flow for Debian/Ubuntu VPSes.
- Existing-relay operator console with MyFamily management, health checks, service controls, logs, backups, package tools, repair tools, and script-trace cleanup.
- Tor Project apt repository setup with signing-key fingerprint verification.
- Apt candidate origin check to ensure `tor` comes from `deb.torproject.org`.
- Candidate `torrc` verification before replacing the live config.
- Monthly traffic budget calculator for steady `RelayBandwidthRate`, `RelayBandwidthBurst`, and `AccountingMax` planning.
- Optional Nyx, UFW, fzf, unattended-upgrades, and Unbound setup.
- WSL Ubuntu dry-run screenshots in the README.
- GitHub Actions CI for syntax, ShellCheck, function tests, and help/version smoke checks.

### Hardened

- Safer backup naming and atomic file replacement.
- Single-run lock for mutating flows.
- Cleanup mode that removes script traces only, not Tor state.
- IPv6 validation and manual-override warnings.
- UFW inactive detection and SSH port preservation.
- Exit relay readiness confirmations.

### Known Beta Boundaries

- The script is interactive and intentionally does not provide a full unattended install mode.
- WSL/container tests cover deterministic logic; real relay reachability still needs a VPS with reachable ORPort and provider firewall access.
- `fzf` is optional. Plain mode remains the fallback and should continue to work everywhere.
