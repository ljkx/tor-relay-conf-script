# Contributing

Thanks for helping make this safer for relay operators.

This project touches privileged server configuration, so changes should be boring in the best possible way: easy to review, explicitly backed by Tor Project documentation, and tested before they ship.

## Ground Rules

- Prefer official Tor Project documentation over blog posts or forum snippets.
- Do not add exit-relay behavior unless it is explicit, opt-in, and documented.
- Do not remove or overwrite operator-owned Tor state without a backup and a very clear confirmation.
- Keep `--plain` working whenever a feature uses `fzf`.
- Keep `--dry-run` useful and non-mutating.
- Keep cleanup limited to traces of this tool, not Tor itself.

## Local Checks

Run these before opening a PR:

```bash
make check
```

The ShellCheck exclusions are intentional:

- `SC2034`: tests assign globals that are consumed by sourced functions.
- `SC2178`: the script uses Bash namerefs for arrays and scalar outputs.

## Pull Request Checklist

- Link the official Tor documentation that justifies behavior changes.
- Include dry-run output or screenshots for UI changes.
- Add or update tests for parsing, generation, or cleanup logic.
- Mention any remaining manual VPS test that cannot be performed locally.
- Do not include secrets, real relay identity keys, private operator emails, or private server IPs in fixtures.

## Release Expectations

A release should include:

- a clean working tree
- passing GitHub Actions
- a tagged release
- `setup-tor-guard-relay.sh` as a release asset
- `SHA256SUMS` for release asset verification
- release notes with exact checks run
