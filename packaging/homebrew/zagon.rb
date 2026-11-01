# Written by release.yml of github.com/a1lezakty/zagon from packaging/homebrew/ in that repo: edit it there.
class Zagon < Formula
  desc "Tracker of Claude Code and Codex CLI sessions: limits, time, tokens, MCP server"
  homepage "https://github.com/a1lezakty/zagon"
  license "MIT"

  # One universal binary for both Mac CPUs (`url` is not allowed in on_macos itself).
  on_macos do
    depends_on macos: :ventura
    on_arm do
      url "https://github.com/a1lezakty/zagon/releases/download/v@VERSION@/zagon-macos-universal"
      sha256 "@SHA256:zagon-macos-universal@"
    end
    on_intel do
      url "https://github.com/a1lezakty/zagon/releases/download/v@VERSION@/zagon-macos-universal"
      sha256 "@SHA256:zagon-macos-universal@"
    end
  end
  on_linux do
    on_intel do
      url "https://github.com/a1lezakty/zagon/releases/download/v@VERSION@/zagon-linux-x86_64"
      sha256 "@SHA256:zagon-linux-x86_64@"
    end
    on_arm do
      url "https://github.com/a1lezakty/zagon/releases/download/v@VERSION@/zagon-linux-aarch64"
      sha256 "@SHA256:zagon-linux-aarch64@"
    end
  end

  def install
    bin.install Dir["zagon-*"].first => "zagon"
  end

  def caveats
    s = <<~EOS
      Connect Claude Code and Codex (hooks, status line, MCP) through the path that stays the same across upgrades:
        zagon install --bin "#{opt_bin}/zagon"
      Without --bin, install writes this version's own Cellar path, which breaks after `brew upgrade`.
      Update with `brew upgrade zagon`, not `zagon update`.
    EOS
    if OS.linux?
      s += <<~EOS
        Add --enable-service to install to start the background service (zagon daemon).
        After `brew upgrade zagon`, restart it: systemctl --user restart zagon
      EOS
    else
      s += <<~EOS
        On a Mac, Zagon.app (brew install --cask a1lezakty/zagon/zagon) collects the data and connects Claude Code
        with the zagon inside it; this formula is the command line alone.
      EOS
    end
    s
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/zagon --version").strip
  end
end
