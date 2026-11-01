# Releasing

A release is a `v<x.y.z>` tag on `main`. `.github/workflows/release.yml` does the rest:

- writes the version into `Sources/ZagonCore/Version.swift` (`zagon --version`, MCP `serverInfo`; a local build says `dev`);
- builds the static Linux binaries `zagon-linux-x86_64` and `zagon-linux-aarch64`;
- writes the release notes first: the tag's annotation, else the commit subjects since the previous tag;
- on macOS runs `apps/macos/scripts/release-mac.sh <version> <run number> notes.md`, which leaves `Zagon.dmg`,
  `Zagon.zip` (the update Sparkle downloads, EdDSA-signed) and `appcast.xml` (with the notes) in `apps/macos/build/`;
  the universal CLI inside the app is also taken out as `zagon-macos-universal` (for Homebrew and the macOS MCPB);
- makes the MCPB bundles and `server.json` from the binaries (`packaging/mcpb/build.sh`, see [MCPB](#mcpb-and-the-mcp-registry));
- attests every file (build provenance, see [Attestations](#attestations));
- publishes a GitHub Release (not a draft or prerelease) with all of them plus `SHA256SUMS`, and checks that
  `releases/latest` is now this release with `appcast.xml`: that is the feed installed apps read;
- then updates the Homebrew tap (see [Homebrew](#homebrew)).

The release files:

| File | What |
|---|---|
| `zagon-linux-x86_64`, `zagon-linux-aarch64` | static Linux CLI (`install.sh`, `zagon update`, Homebrew on Linux) |
| `zagon-macos-universal` | the macOS CLI, arm64 + x86_64, the same one Zagon.app carries (Homebrew formula on macOS) |
| `Zagon.dmg` | the app, for a manual install and the Homebrew cask |
| `Zagon.zip`, `appcast.xml` | the Sparkle update and its feed |
| `zagon-mcp-macos.mcpb`, `zagon-mcp-linux-x86_64.mcpb`, `zagon-mcp-linux-aarch64.mcpb` | `zagon mcp` as an MCP bundle (Claude Desktop and other MCPB clients) |
| `server.json` | the MCP Registry entry of this version (the macOS bundle with its sha256) |
| `SHA256SUMS` | sums of all of the above; `install.sh` and `zagon update` read it by file name |

Do not rename the existing files: installed copies look them up by name.

Installed copies pick it up from there: `zagon update` and `install.sh` read
`releases/latest/download/SHA256SUMS` and the binary for their CPU; Zagon.app reads
`releases/latest/download/appcast.xml` once a day.

## Cut a version

```sh
git switch main && git pull
git tag -a v0.2.0 -m "What changed, in a few lines"   # becomes the release notes
git push origin v0.2.0
```

The notes of every release start with this paragraph. Put it first in a file, then what changed, and tag with
`git tag -a v0.2.0 -F notes.md` (the first paragraph of an annotation is its subject, and the release notes are the
subject, an empty line and the rest):

```text
**Mac, first launch:** Zagon.app is ad-hoc signed, not notarized, so macOS blocks it the first time. Open Zagon.dmg and drag Zagon to Applications; open it from there and click Done when macOS says it cannot verify the developer; then System Settings → Privacy & Security → Open Anyway next to the Zagon message, and confirm. Only once: after that the app updates itself.
```

Sparkle shows the notes in the update alert too, so installed apps see the paragraph as well.

Without `-a` (a lightweight tag) the notes are the commit subjects since the previous tag. Versions are `x.y.z`
only, and each must be higher than the last (the workflow refuses one that is not above every `v*` tag): Sparkle
compares the build number (the workflow's run number) and `zagon update` takes whatever `latest` is.

If the run fails, fix the cause and use **Re-run failed jobs**, not "Re-run all jobs": the jobs that passed keep
their files, and the publish step finds a release left by a failed upload (even a draft), uploads again and makes it
the published `latest`.

## Try the workflow without releasing

Actions → release → Run workflow, with the next `version` (above the last tag). It builds and checks every file and
uploads them with `SHA256SUMS` to the run as the artifact `release-files`; nothing is published. No attestations
are made, and the Homebrew job only renders the tap files (artifact `homebrew`) without pushing them.

## Attestations

The `attest` job (tags only) signs a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)
for every release file with `actions/attest-build-provenance` (Sigstore; stored by GitHub with the repository). It
is the only job with `id-token: write` and `attestations: write`, and it runs before the release, so no file is
published without one. Manual runs make none: they build any branch, and their attestations would verify just the
same for files that were never released. Check one:

```sh
gh attestation verify zagon-linux-x86_64 --repo a1lezakty/zagon
```

## Homebrew

The tap is the repository `a1lezakty/homebrew-zagon`: `Formula/zagon.rb` (the CLI: the Linux binaries,
`zagon-macos-universal` on macOS) and `Casks/zagon.rb` (Zagon.app from `Zagon.dmg`). Their templates are in
`packaging/homebrew/`; after the release, the `homebrew` job fills in the version and the sums from `SHA256SUMS`
(`packaging/homebrew/render.sh`) and pushes both files to the tap. Without the tap or the token it is skipped with
a notice; it runs after the release, so a failure there leaves the release as it is (fix, then **Re-run failed
jobs**). Change the formula or the cask in the templates, not in the tap: the next release overwrites the tap.

Set it up once:

1. Create the public repository `a1lezakty/homebrew-zagon` with a README (so it has a default branch).
2. Create a fine-grained personal access token: repository access **only** `a1lezakty/homebrew-zagon`, permission
   Contents: Read and write, nothing else (GITHUB_TOKEN cannot push to another repository). Give it an expiry and
   renew it.
3. Add it to this repository as the Actions secret `HOMEBREW_TAP_TOKEN`.
4. Release, or re-run the `homebrew` job of the last tag run. Then on a Mac and a Linux box:
   `brew install a1lezakty/zagon/zagon`, `brew install --cask a1lezakty/zagon/zagon`, `brew test zagon`.

Users install with the full name (Homebrew 6 trusts only that item of a third-party tap):

```sh
brew install a1lezakty/zagon/zagon                # CLI, macOS and Linux
brew install --cask a1lezakty/zagon/zagon         # Zagon.app
```

The formula's caveats say to run `zagon install --bin "$(brew --prefix)/opt/zagon/bin/zagon"`, to update with
`brew upgrade` (not `zagon update`) and to restart the Linux service after an upgrade. The cask declares
`auto_updates true` (Sparkle updates the app; `brew upgrade` takes the cask only when the installed app is older), quits the app on uninstall
and with `--zap` moves `~/.zagon` (shared with the formula) and the app's Library files to the Trash. Homebrew puts
the quarantine flag on the download, so the first launch needs Open Anyway as with the DMG; the cask does not remove
the flag (Homebrew 5 deprecated `--no-quarantine`). Such a cask is fine in our own tap but not in `homebrew/cask`,
which accepts only apps that pass Gatekeeper (signed with a Developer ID and notarized).

## MCPB and the MCP Registry

`packaging/mcpb/build.sh` (in the `bundle` job) makes one [MCPB](https://github.com/modelcontextprotocol/mcpb) per
platform: a zip with `manifest.json` (template `packaging/mcpb/manifest.json`, `manifest_version` 0.3,
`server.type` `binary`, run as `${__dirname}/server/zagon mcp`) and the executable `server/zagon`. The tools list
in the manifest is asked from the release's own `zagon-linux-x86_64` (`tools/list`), so it always matches; the job
fails if the server does not answer with this version. Check a bundle by hand with the official CLI, in Docker:

```sh
docker run --rm -v "$PWD:/m" node:22 sh -c 'npx -y @anthropic-ai/mcpb validate /m/manifest.json'
```

`server.json` is the [MCP Registry](https://registry.modelcontextprotocol.io) entry `io.github.a1lezakty/zagon` of
this version: the package `zagon-mcp-macos.mcpb` (registry type `mcpb`, its URL on the release and `fileSha256`).
Only the macOS bundle is listed: a registry entry has no field for the platform, and MCPB clients (Claude Desktop)
run on macOS. Publish after the release is out, by hand
([mcp-publisher](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/quickstart.mdx)):

```sh
mkdir mcp-registry && cd mcp-registry
curl -fsSLO https://github.com/a1lezakty/zagon/releases/download/v0.2.0/server.json
mcp-publisher login github      # as a1lezakty: the io.github.a1lezakty/ namespace
mcp-publisher publish           # reads ./server.json
```

The registry keeps each version once: a published version cannot be changed, only a newer one published.

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
