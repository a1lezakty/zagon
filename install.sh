#!/bin/sh
# Installs the latest zagon release on Linux:
#   curl -fsSL https://raw.githubusercontent.com/a1lezakty/zagon/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/a1lezakty/zagon/main/install.sh | sh -s -- --enable-service
# Arguments go to `zagon install`. The binary goes to /usr/local/bin as root, else ~/.local/bin (ZAGON_BIN_DIR
# overrides). ZAGON_RELEASE_URL (https) picks another release, e.g. https://github.com/a1lezakty/zagon/releases/download/v0.1.0
set -eu
# all in main(): a cut-off download runs nothing, and `zagon install` does not read the rest of the script
main() {
  url=${ZAGON_RELEASE_URL:-https://github.com/a1lezakty/zagon/releases/latest/download}
  url=${url%/}

  case $(uname -s) in
    Linux) ;;
    Darwin) echo "On macOS install Zagon.app: download Zagon.dmg from https://github.com/a1lezakty/zagon/releases/latest"; exit 0 ;;
    *) echo "zagon: no release for $(uname -s); build from source" >&2; exit 1 ;;
  esac
  case $(uname -m) in
    x86_64|amd64) asset=zagon-linux-x86_64 ;;
    aarch64|arm64) asset=zagon-linux-aarch64 ;;
    *) echo "zagon: no release for $(uname -m); build from source" >&2; exit 1 ;;
  esac
  for t in curl sha256sum; do command -v $t >/dev/null || { echo "zagon: $t is needed" >&2; exit 1; }; done

  if [ -n "${ZAGON_BIN_DIR:-}" ]; then dir=$ZAGON_BIN_DIR
  elif [ "$(id -u)" = 0 ]; then dir=/usr/local/bin
  else dir=$HOME/.local/bin
  fi
  mkdir -p "$dir"
  # same directory as the binary, so the final mv is atomic
  tmp=$(mktemp "$dir/.zagon-install.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  trap 'exit 130' INT TERM

  want=$(curl --proto '=https' --tlsv1.2 -fsSL "$url/SHA256SUMS" | awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }')
  [ -n "$want" ] || { echo "zagon: cannot read $url/SHA256SUMS, or $asset is not listed there" >&2; exit 1; }
  echo "Downloading $url/$asset"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp" "$url/$asset"
  got=$(sha256sum "$tmp" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "zagon: checksum mismatch for $asset; nothing installed" >&2; exit 1; }
  chmod 755 "$tmp"
  mv -f "$tmp" "$dir/zagon"
  echo "Installed $dir/zagon $("$dir/zagon" --version)"

  "$dir/zagon" install "$@"
  # services already running this binary (an upgrade over an older install) pick up the new binary or unit file:
  # system units, this account's user unit and the one of the account installed for (--user, else the sudo user)
  user=; prev=
  for a in "$@"; do
    case $prev in --user) user=$a ;; esac
    case $a in --user=*) user=${a#--user=} ;; esac
    prev=$a
  done
  "$dir/zagon" update --restart-services ${user:+--user "$user"} 2>/dev/null || true
  case :$PATH: in *":$dir:"*) ;; *) echo "Add $dir to PATH to run zagon by name." ;; esac
}
main "$@"
