#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: tools/thin-sparkle.sh <Sparkle.framework> [temporary-directory]" >&2
  exit 64
fi

framework="$1"
temporary_directory="${2:-${TMPDIR:-/tmp}}"
version="$framework/Versions/B"
test -d "$version"
mkdir -p "$temporary_directory"

binaries=(
  "$version/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$version/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$version/Autoupdate"
  "$version/Updater.app/Contents/MacOS/Updater"
  "$version/Sparkle"
)

for binary in "${binaries[@]}"; do
  test -f "$binary"
  architectures="$(lipo -archs "$binary")"
  case " $architectures " in
    *' arm64 '*) ;;
    *) echo "Sparkle component has no arm64 slice: $binary" >&2; exit 1 ;;
  esac
  if [[ "$architectures" != 'arm64' ]]; then
    mode="$(stat -f '%Lp' "$binary")"
    temporary="$(mktemp "$temporary_directory/cellar-sparkle.XXXXXX")"
    lipo "$binary" -thin arm64 -output "$temporary"
    mv "$temporary" "$binary"
    chmod "$mode" "$binary"
  fi
done

for binary in "${binaries[@]}"; do
  test "$(lipo -archs "$binary")" = 'arm64'
done
