# Releasing

A release is a `v<x.y.z>` tag on `main`. `.github/workflows/release.yml` does the rest:

- writes the version into `Sources/zagon/Version.swift` (`zagon --version`; a local build says `dev`);
- builds the static Linux binaries `zagon-linux-x86_64` and `zagon-linux-aarch64`;
- writes the release notes first: the tag's annotation, else the commit subjects since the previous tag;
- on macOS runs `apps/macos/scripts/release-mac.sh <version> <run number> notes.md`, which leaves `Zagon.dmg`,
  `Zagon.zip` (the update Sparkle downloads, EdDSA-signed) and `appcast.xml` (with the notes) in `apps/macos/build/`;
- publishes a GitHub Release (not a draft or prerelease) with all of them plus `SHA256SUMS`, and checks that
  `releases/latest` is now this release with `appcast.xml`: that is the feed installed apps read.

Installed copies pick it up from there: `zagon update` and `install.sh` read
`releases/latest/download/SHA256SUMS` and the binary for their CPU; Zagon.app reads
`releases/latest/download/appcast.xml` once a day.

## Cut a version

```sh
git switch main && git pull
git tag -a v0.2.0 -m "What changed, in a few lines"   # becomes the release notes
git push origin v0.2.0
```

Without `-a` (a lightweight tag) the notes are the commit subjects since the previous tag. Versions are `x.y.z`
only, and each must be higher than the last: Sparkle compares the build number (the workflow's run number) and
`zagon update` takes whatever `latest` is.

## Try the workflow without releasing

Actions → release → Run workflow, with a `version` such as `0.0.0`. It builds and checks every file and uploads them
with `SHA256SUMS` to the run as the artifact `release-files`; nothing is published.

## The Sparkle key

The app ships the public key (`SUPublicEDKey` in `Info.plist`, set by `apps/macos/scripts/build-app.sh`). The private
key is the repository secret `SPARKLE_ED_PRIVATE_KEY` (base64, as `generate_keys -x` exports it). The secret cannot
be read back, so keep an offline copy of the key: the app's signature is ad-hoc, there is no Apple signature to fall
back on. `release-mac.sh` refuses to publish an update whose signature does not match
the public key in the app.

If the private key is lost, installed apps cannot accept updates signed with a new one: ship the new public key in a
release, and users have to install that release from the DMG by hand.

## Roll back

Release a fixed version: Sparkle never installs an older build, so apps that already took the bad one only move on
with a newer one. To stop more installs meanwhile, delete the bad release on GitHub (`latest` falls back to the
previous one). On a server, `zagon.prev` next to the binary is the version before the last `zagon update`. A rollback
across a schema change does not work: the database is not rolled back, and the older binary refuses a newer database.
