# Written by release.yml of github.com/a1lezakty/zagon from packaging/homebrew/ in that repo: edit it there.
cask "zagon" do
  version "@VERSION@"
  sha256 "@SHA256:Zagon.dmg@"

  url "https://github.com/a1lezakty/zagon/releases/download/v#{version}/Zagon.dmg"
  name "Zagon"
  desc "Menu bar app for Jira worklogs, limits and time of Claude Code and Codex"
  homepage "https://github.com/a1lezakty/zagon"

  auto_updates true
  depends_on macos: :ventura

  app "Zagon.app"

  uninstall quit: "dev.zagon.app"

  # ~/.zagon is the database, the transcript archive and the settings, shared with the zagon formula: zap moves it
  # to the Trash with the rest.
  zap trash: [
    "~/.zagon",
    "~/Library/Caches/dev.zagon.app",
    "~/Library/HTTPStorages/dev.zagon.app",
    "~/Library/Logs/Zagon",
    "~/Library/Preferences/dev.zagon.app.plist",
    "~/Library/Saved Application State/dev.zagon.app.savedState",
  ]

  caveats <<~EOS
    Zagon.app is ad-hoc signed, not notarized, so macOS blocks its first launch. Open it once from Applications
    and click Done when macOS says it cannot verify the developer, then go to System Settings → Privacy & Security,
    click Open Anyway next to the Zagon message and confirm. Only once: after that the app updates itself.

    Before uninstalling, click Disconnect in Zagon's window (Claude Code and Codex), or run
      /Applications/Zagon.app/Contents/Helpers/zagon uninstall
    so the Claude Code and Codex settings no longer run the zagon inside the app.

    brew uninstall --zap also moves ~/.zagon to the Trash: the database and the transcript archive, which may be
    the only copy of transcripts Claude Code has already deleted.
  EOS
end
