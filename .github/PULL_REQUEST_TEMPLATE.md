## Summary

-

## Safety Notes

- [ ] This keeps `--dry-run` non-mutating.
- [ ] This keeps `--plain` working.
- [ ] This does not remove Tor state, relay identity, or operator-owned config without explicit confirmation.
- [ ] Official Tor Project documentation was checked for relay behavior changes.

## Checks

- [ ] `bash -n setup-tor-guard-relay.sh`
- [ ] `shellcheck -S warning -e SC2034,SC2178 setup-tor-guard-relay.sh tests/test-functions.bash`
- [ ] `bash tests/test-functions.bash`
- [ ] `./setup-tor-guard-relay.sh --help`
- [ ] `./setup-tor-guard-relay.sh --version`
