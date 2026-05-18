# Operator Guide

This guide is the practical companion to the installer. It keeps the day-two relay tasks in one place.

## Before Running

Have these ready:

- relay nickname, 1 to 19 letters/numbers
- public `ContactInfo` string
- ORPort, usually `9001`
- monthly traffic budget or desired bandwidth
- whether the server has working IPv6
- whether the provider firewall also needs an inbound TCP rule
- for exits only: provider permission and abuse handling plan

Run a dry run first:

```bash
./setup-tor-guard-relay.sh --dry-run
```

## After Setup

Check the service:

```bash
systemctl status tor@default --no-pager
```

Follow logs:

```bash
journalctl -u tor@default -f
```

Look for the ORPort self-test:

```bash
journalctl -u tor@default --since "1 hour ago" | grep -F "Self-testing indicates"
```

Check Relay Search after a few hours:

```text
https://metrics.torproject.org/rs.html
```

## MyFamily

Use MyFamily when the same operator controls more than one public relay.

Rules of thumb:

- use fingerprints, not nicknames
- expect torrc entries to prefix each fingerprint with `$`; that is Tor's documented `MyFamily` syntax
- include every relay controlled by the same operator
- apply the same family value on every relay in the family
- expect directory publication to lag behind local config changes

Run the script again on an existing relay to open the operator console:

```bash
sudo ./setup-tor-guard-relay.sh
```

Then choose `Manage MyFamily`.

## Bandwidth Planning

Steady monthly mode is for VPS quotas. It tries to keep the relay useful throughout the billing period.

Manual rate mode is better when you already know the bandwidth you want to donate.

Hard `AccountingMax` alone is a fuse, not a pacing strategy. If the relay reaches the cap early, Tor can hibernate and disappear until the accounting period resets.

## Exit Relay Notes

Exit relays are important, but they need more preparation.

Before choosing exit mode:

- confirm the provider allows Tor exits
- prepare abuse complaint handling
- consider reverse DNS or WHOIS notes
- use reliable local DNS, preferably Unbound as guided by Tor Project docs
- understand the selected exit policy

The script asks for explicit confirmation before configuring exit behavior.

## Backups

The script creates timestamped config backups before replacing important files.

Examples:

```text
/etc/tor/torrc.bak.20260518T120000Z
/etc/hosts.bak.20260518T120000Z
```

Relay identity keys live under `/var/lib/tor/keys` by default. Back them up carefully after the relay is stable. Treat the archive as sensitive.

## Cleanup

`--uninstall` means “remove traces of this tool,” not “remove Tor.”

It does not remove:

- Tor
- `/etc/tor/torrc`
- `/var/lib/tor`
- relay identity keys
- firewall rules
- Tor logs
- Unbound
- hostname changes

That is intentional. Relay state belongs to the operator.
