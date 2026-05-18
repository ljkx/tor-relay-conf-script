# Release Guide

This is the release checklist for maintainers.

## Preflight

```bash
git status --short
make check
```

Run a guided dry-run capture for README screenshots when UI output changes.

## Create Assets

```bash
VERSION="v1.0.0-beta.2"
mkdir -p release-assets
cp setup-tor-guard-relay.sh release-assets/
(cd release-assets && sha256sum setup-tor-guard-relay.sh > SHA256SUMS)
```

Verify:

```bash
(cd release-assets && sha256sum -c SHA256SUMS)
```

## Tag And Release

```bash
git tag -a "$VERSION" -m "$VERSION"
git push origin main "$VERSION"
gh release create "$VERSION" \
  release-assets/setup-tor-guard-relay.sh \
  release-assets/SHA256SUMS \
  --title "$VERSION" \
  --notes-file release-assets/RELEASE_NOTES.md \
  --prerelease
```

## After Release

- Confirm GitHub Actions passed for the release commit.
- Confirm release assets are uploaded.
- Confirm README quick-start version matches the release tag.
- Confirm the release asset checksum matches `SHA256SUMS`.
