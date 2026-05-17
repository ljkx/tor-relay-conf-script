# Tor Relay Setup

<p align="center">
  <img alt="Tor relay modes" src="https://img.shields.io/badge/Tor-guard%20%2F%20exit%20relay-7D4698?style=for-the-badge">
  <img alt="Bash installer" src="https://img.shields.io/badge/Bash-interactive%20installer-1f425f?style=for-the-badge&logo=gnubash&logoColor=white">
  <img alt="Debian and Ubuntu" src="https://img.shields.io/badge/Debian%20%2F%20Ubuntu-supported-a81d33?style=for-the-badge&logo=debian&logoColor=white">
  <img alt="MIT license" src="https://img.shields.io/badge/License-MIT-2b9348?style=for-the-badge">
</p>

```text
  ============================================================
       Tor Relay Setup
  ============================================================
       A guided installer for public Tor relays
```

This repo is a small, opinionated Bash installer for turning a fresh Debian or Ubuntu VPS into a public Tor relay. It can configure a Guard/middle relay or, when you intentionally choose it, an exit relay with the Tor Project's recommended exit basics. It is meant for the person who knows the practical details, like a relay nickname, contact address, bandwidth expectations, whether the server has IPv6, and whether this VPS is supposed to exit traffic, but does not want to hand-edit `torrc` at midnight.

## Status

This is experimental software, but it works pretty well in real VPS testing so far. Treat it like a sharp tool: read it, run `--dry-run`, and only then let it touch a server.

Implementation note: this repository was built solely by **Codex 5.5 xhigh** from the project requirements and test feedback. Human input supplied the goal, review direction, and live VPS logs; the implementation itself was generated and iterated by Codex.

## Quick Start

Clone it, review it, and run it:

```bash
git clone https://github.com/ljkx/tor-relay-conf-script.git
cd tor-relay-conf-script
less setup-tor-guard-relay.sh
./setup-tor-guard-relay.sh --dry-run
sudo ./setup-tor-guard-relay.sh
```

Download and start it in one line:

```bash
curl -fsSLo setup-tor-guard-relay.sh "https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh?$(date +%s)" && chmod +x setup-tor-guard-relay.sh && sudo ./setup-tor-guard-relay.sh
```

With `wget` instead:

```bash
wget -O setup-tor-guard-relay.sh "https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh?$(date +%s)" && chmod +x setup-tor-guard-relay.sh && sudo ./setup-tor-guard-relay.sh
```

Direct pipe mode also works on fresh VPSes after you have reviewed the script:

```bash
curl -fsSL "https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh?$(date +%s)" | sudo bash
```

With `wget` instead:

```bash
wget -qO- "https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh?$(date +%s)" | sudo bash
```

Dry-run from the remote script:

```bash
curl -fsSL "https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh?$(date +%s)" | bash -s -- --dry-run
```

If GitHub's raw CDN ever serves an older copy, the `?$(date +%s)` part forces a fresh fetch. The startup banner also prints the script version.

Show help:

```bash
./setup-tor-guard-relay.sh --help
```

## Supported Systems

The installer supports Debian and Ubuntu releases when the official Tor Project apt repository publishes packages for that release codename.

Known-good examples include:

- Debian 12 `bookworm`
- Debian 13 `trixie`
- Debian `forky`
- Ubuntu 22.04 LTS `jammy`
- Ubuntu 24.04 LTS `noble`
- Ubuntu `questing`
- Ubuntu 26.04 LTS `resolute`

The script detects the OS codename from `/etc/os-release`, verifies that `https://deb.torproject.org/torproject.org/dists/<codename>/Release` exists, and then uses that codename for the Tor Project apt source.

The script expects a systemd-based Debian-family VPS with `apt`, `dpkg`, and either `amd64` or `arm64`, matching the architectures currently provided by the Tor Project Debian package repository.

## What It Asks

The installer walks through the choices that actually matter:

- Optional Linux system hostname change for fresh VPSes
- Relay mode: Guard/middle or exit
- Relay nickname
- Public `ContactInfo` email or contact string
- ORPort, default `9001`
- Optional IPv6 ORPort
- Exit relay options when exit mode is selected: provider readiness, reduced or default exit policy, optional IPv6 exiting, and local Unbound DNS setup
- Optional `RelayBandwidthRate` / `RelayBandwidthBurst`
- Optional monthly `AccountingMax`
- Automatic package updates
- Optional Nyx install for terminal relay monitoring
- Firewall rule management when a supported firewall is detected
- Basic hardening via Tor `SafeLogging 1` and optional `Sandbox 1`

It shows a final summary before doing privileged work, then asks for confirmation again.

## What It Changes

When confirmed, the script:

- Detects Debian/Ubuntu version and CPU architecture.
- Optionally changes the Linux system hostname with `hostnamectl` and updates `/etc/hosts`.
- Configures the official Tor Project apt repository in `/etc/apt/sources.list.d/tor.sources`.
- Installs the Tor Project signing key at `/usr/share/keyrings/deb.torproject.org-keyring.gpg`.
- Installs `tor`.
- Installs `deb.torproject.org-keyring` when apt publishes it for the detected suite. New suites sometimes publish `tor` before the keyring package, so the script continues with the manually installed keyring file when needed.
- Optionally installs `nyx` for terminal relay monitoring.
- Backs up `/etc/tor/torrc` before replacing it with the generated relay configuration.
- Writes `ExitRelay 0` for Guard/middle mode.
- Writes `ExitRelay 1` for exit mode, with `ReducedExitPolicy 1` by default unless you choose Tor's broader default exit policy.
- Optionally writes `IPv6Exit 1` when exit mode and IPv6 ORPort are both selected.
- Optionally installs and starts `unbound` for exit relay DNS, backs up `/etc/resolv.conf`, and points the system resolver at `127.0.0.1`.
- Optionally installs and configures `unattended-upgrades` for security and Tor updates.
- Optionally opens the selected ORPort using detected `ufw`, active `firewalld`, or a supported `nftables` chain.
- Enables and restarts `tor@default`.
- Verifies Tor config syntax, service status, local ORPort listener, and Tor's post-start ORPort reachability self-test when possible.
- Checks apt-related disk space and inode availability before package operations.

Backups are timestamped, for example:

```text
/etc/tor/torrc.bak.20260518T120000Z
```

When the optional hostname change is selected, `/etc/hostname` and `/etc/hosts` are backed up before modification.

## Generated torrc Shape

Guard/middle mode follows the Tor Project's Middle/Guard relay guidance:

```torrc
Nickname MyRelay
ContactInfo "operator@example.org"
ORPort 9001
SocksPort 0
ExitRelay 0
SafeLogging 1
```

Exit mode uses Tor's exit relay guidance and defaults to the reduced exit policy for a first exit:

```torrc
Nickname MyExit
ContactInfo "operator@example.org"
ORPort 9001
SocksPort 0
ExitRelay 1
ReducedExitPolicy 1
SafeLogging 1
```

Optional settings are added only when selected, such as:

```torrc
ORPort [2001:db8::1234]:9001
IPv6Exit 1
RelayBandwidthRate 16 MBits
RelayBandwidthBurst 32 MBits
AccountingStart month 1 00:00
AccountingMax 2000 GBytes
Sandbox 1
```

## Security Notes

- Always review privileged scripts before running them on a server.
- `ContactInfo` is public. Use an address or contact string you are comfortable publishing.
- Guard/middle mode writes `ExitRelay 0`; exit mode writes `ExitRelay 1` and the exit policy you selected.
- Exit relays need more operational care than Guard/middle relays. Use a provider that allows exit traffic, plan abuse handling, and consider reverse DNS / WHOIS notes that clearly identify the server as a Tor exit.
- For exit mode, the script can install Unbound and switch `/etc/resolv.conf` to `nameserver 127.0.0.1`, matching Tor's Debian/Ubuntu exit relay DNS guidance. It backs up the old resolver config first.
- The optional `/etc/resolv.conf` lock uses `chattr +i`. That can be useful on VPSes where DHCP keeps rewriting DNS, but you must unlock it manually with `sudo chattr -i /etc/resolv.conf` before future resolver changes.
- Keep SSH access open. The script only adds an ORPort firewall allow rule; it does not enable an inactive firewall or change default policies.
- Cloud firewalls are outside the VPS. Open the ORPort in your provider panel if required.
- The IPv6 prompt's early connectivity check is outbound-only and follows Tor's documented ping test against directory authority IPv6 addresses. Some networks make ICMPv6/ping awkward, so the script shows per-address results and lets an operator keep IPv6 enabled after manual verification.
- Inbound ORPort reachability is checked only after the firewall rule is applied and Tor restarts.
- The optional system hostname is local server identity only. It is separate from the public Tor relay `Nickname`.
- Tor relay operators should keep Tor and the operating system updated.
- Leave Tor logs at notice level and keep `SafeLogging` enabled unless debugging a specific issue.
- Do not publish real-time relay/system metrics. Tor recommends aggregation windows of at least a day when publishing statistics.
- If you operate multiple relays, configure `MyFamily` manually after you know each relay fingerprint.
- After the relay is running, consider securely backing up `/var/lib/tor/keys`. Those identity keys are sensitive.
- The script collects no secrets and implements no telemetry.

## Relay Lifecycle

New relays do not receive full traffic immediately. This is normal, not a sign that the script failed.

- Tor's post-install guidance says a new relay should appear in Relay Search after about 3 hours.
- Traffic can be low for the first few days while bandwidth authorities measure the relay.
- Guard behavior depends on stable uptime and sufficient bandwidth; it can take time to receive and fully ramp into Guard usage.

Relay Search:

```text
https://metrics.torproject.org/rs.html
```

## Troubleshooting

Check service state:

```bash
systemctl status tor@default --no-pager
```

Follow logs:

```bash
journalctl -u tor@default -f
```

Look for the expected ORPort self-test:

```bash
journalctl -u tor@default --since "1 hour ago" | grep -F "Self-testing indicates"
```

Check the listener:

```bash
ss -ltn | grep ':9001'
```

Open Nyx if you installed it:

```bash
sudo -u debian-tor nyx
```

Check Unbound on an exit relay:

```bash
systemctl status unbound --no-pager
getent hosts deb.torproject.org
cat /etc/resolv.conf
```

Verify the Tor config manually:

```bash
tor --verify-config -f /etc/tor/torrc
```

Common issues:

- `apt` reports `No space left on device`: the VPS filesystem or inode table is full. Check `df -h` and `df -ih`, then free space before re-running.
- Provider firewall or security group does not allow inbound TCP ORPort.
- Local firewall did not have a supported manager or ruleset.
- IPv6 was enabled without working IPv6 connectivity. The early ping check is outbound ICMPv6; the later Tor self-test is the better signal for inbound ORPort reachability.
- Port is already in use.
- VPS does not have a public IPv4 address.
- Exit mode was selected on a provider that blocks exit traffic or outbound DNS.
- `/etc/resolv.conf` was locked with `chattr +i` and needs to be unlocked before changing DNS again.

If an earlier package operation was interrupted by a full disk, clear the apt cache and retry after freeing space:

```bash
sudo apt clean
sudo rm -rf /var/lib/apt/lists/partial/*
sudo apt update
```

Restore an earlier resolver backup if you experimented with exit DNS and need to roll back:

```bash
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo cp -a /etc/resolv.conf.bak.YYYYMMDDTHHMMSSZ /etc/resolv.conf
```

## Updating

If unattended upgrades were enabled, security and Tor package updates should be applied automatically.

Manual update:

```bash
sudo apt update
sudo apt install --only-upgrade tor
apt-cache policy deb.torproject.org-keyring
sudo systemctl restart tor@default
```

## Uninstalling

Stop and disable Tor:

```bash
sudo systemctl disable --now tor@default
```

Remove packages if you no longer want Tor installed:

```bash
sudo apt remove tor
```

If you installed Unbound only for exit relay DNS and no longer need it:

```bash
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo systemctl disable --now unbound
sudo apt remove unbound
```

Optional cleanup:

```bash
sudo rm /etc/apt/sources.list.d/tor.sources
sudo rm /usr/share/keyrings/deb.torproject.org-keyring.gpg
sudo apt update
```

Remove `/var/lib/tor` only if you intentionally want to delete relay identity keys and lose relay reputation:

```bash
sudo rm -rf /var/lib/tor
```

## Official Tor Sources

This script was built from current official Tor documentation, including:

- [Tor relay technical setup](https://community.torproject.org/relay/setup/)
- [Debian/Ubuntu Middle/Guard relay setup](https://community.torproject.org/relay/setup/guard/debian-ubuntu/)
- [Types of relays on the Tor network](https://community.torproject.org/relay/types-of-relays/)
- [Exit relay setup](https://community.torproject.org/relay/setup/exit/)
- [Debian/Ubuntu exit relay DNS setup](https://community.torproject.org/relay/setup/exit/debian-ubuntu/)
- [Tor Debian/Ubuntu package installation](https://support.torproject.org/little-t-tor/getting-started/installing/)
- [Relay post-install and good practices](https://community.torproject.org/relay/setup/post-install/)
- [Relay requirements](https://community.torproject.org/relay/relays-requirements/)
- [Technical considerations](https://community.torproject.org/relay/technical-considerations/)
- [Bandwidth limits](https://support.torproject.org/relays/performance/bandwidth-limits/)
- [Expectations for relay operators](https://community.torproject.org/policies/relays/expectations-for-relay-operators/)
- [Lifecycle of a new relay](https://blog.torproject.org/lifecycle-of-a-new-relay/)

When in doubt, prefer Tor Project documentation over third-party guides.
