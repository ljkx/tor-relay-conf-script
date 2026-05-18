# Security Policy

This project configures privileged Linux services. Treat every change as security-sensitive.

## Supported Versions

| Version | Status |
| --- | --- |
| `v1.0.0-beta.1` | Beta, security fixes accepted |
| earlier commits | Not supported as releases |

## Reporting a Vulnerability

Please avoid posting sensitive server details in public issues.

Safe to share publicly:

- distro and codename
- script version
- selected relay mode
- sanitized `torrc` directives
- error messages with private data removed

Do not share publicly:

- relay identity keys
- private SSH keys
- private contact addresses you do not want published
- VPS control-panel credentials
- complete logs that may include local operational context

For urgent security issues, open a GitHub issue with a minimal public summary and mark clearly that details are sensitive. If GitHub private vulnerability reporting is enabled for the repository, use that path.

## Security Boundaries

The script is designed to:

- configure Tor from official Tor Project apt packages
- back up important files before replacement
- verify generated `torrc` candidates before installing them
- avoid telemetry and secret collection
- keep cleanup limited to traces of this tool

The script is not designed to:

- harden an already compromised server
- replace provider firewall configuration
- provide legal advice for exit relay operation
- manage Tor bridge relays
- erase Tor relay identity or decommission a relay automatically
