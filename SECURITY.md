# Security

## Report a vulnerability

Report it privately through GitHub: [Security → Report a vulnerability](https://github.com/a1lezakty/zagon/security/advisories/new)
(private vulnerability reporting). Please do not open a public issue for it. Say what is affected (version, Linux
or macOS, CLI or app), how to reproduce it, and what an attacker gains. You get an answer in the advisory; the fix
ships in a new release, and the advisory is published with it.

## Supported versions

Only the latest release gets fixes. Update with `zagon update` (Linux), `brew upgrade` if you installed with
Homebrew, or let Zagon.app update itself.

## What Zagon touches

Zagon runs locally and has no telemetry. It reads Claude Code transcripts and Codex session files and keeps its
database, settings and transcript archive in `~/.zagon`; tokens you give it (Jira, Telegram) stay in files only you
can read. Its install step adds hooks, a status line wrapper and an MCP server to the Claude Code and Codex settings
(backed up first). Its network requests are only the notifications and Jira you configure, and updates. Details:
[README, Privacy](README.md#privacy).

## Verify a download

Every release has `SHA256SUMS`, and from 0.1.5 on a signed build provenance attestation for each of its files:

```sh
sha256sum -c --ignore-missing SHA256SUMS     # in the folder with the downloads; on macOS: shasum -a 256 -c …
gh attestation verify zagon-linux-x86_64 --repo a1lezakty/zagon
```

`gh attestation verify` (GitHub CLI) checks the file's Sigstore-signed provenance: that it was built by
`.github/workflows/release.yml` of this repository from a `v*` tag. It works for every release file, `Zagon.dmg` and
the `.mcpb` bundles included. `install.sh` and `zagon update` check the binary against `SHA256SUMS` before they install it.

## macOS app

Zagon.app is ad-hoc signed and not notarized (there is no paid Apple developer account), so macOS asks you to allow
it once on first launch (System Settings → Privacy & Security → Open Anyway). Its updates are signed with an
EdDSA key (Sparkle): the app installs an update only if its signature matches the public key built into it, and
the private key exists only as a secret of this repository's release workflow.
