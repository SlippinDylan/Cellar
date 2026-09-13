#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_DIR="$(cd "$NODE_DIR/../node-manager" && pwd)"
TOOLS_DIR="$MANAGER_DIR/.runtime/tools"
DOWNLOAD_DIR="$TOOLS_DIR/downloads"
SHELLCHECK_DIR="$TOOLS_DIR/shellcheck"
VERSION="${SHELLCHECK_VERSION:-v0.11.0}"
SHELLCHECK_SHA256="${SHELLCHECK_SHA256:-}"

case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        asset="shellcheck-${VERSION}.darwin.aarch64.tar.xz"
        ;;
    Darwin:x86_64)
        asset="shellcheck-${VERSION}.darwin.x86_64.tar.xz"
        ;;
    Linux:aarch64)
        asset="shellcheck-${VERSION}.linux.aarch64.tar.xz"
        ;;
    Linux:x86_64)
        asset="shellcheck-${VERSION}.linux.x86_64.tar.xz"
        ;;
    *)
        printf "unsupported platform for bundled ShellCheck: %s %s\n" "$(uname -s)" "$(uname -m)" >&2
        exit 1
        ;;
esac

archive_path="$DOWNLOAD_DIR/$asset"
download_url="https://github.com/koalaman/shellcheck/releases/download/${VERSION}/${asset}"

shellcheck_expected_sha256() {
    if [ -n "$SHELLCHECK_SHA256" ]; then
        printf '%s\n' "$SHELLCHECK_SHA256"
        return 0
    fi

    case "$asset" in
        shellcheck-v0.11.0.darwin.aarch64.tar.xz)
            printf '%s\n' "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79"
            ;;
        shellcheck-v0.11.0.darwin.x86_64.tar.xz)
            printf '%s\n' "3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6"
            ;;
        shellcheck-v0.11.0.linux.aarch64.tar.xz)
            printf '%s\n' "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
            ;;
        shellcheck-v0.11.0.linux.x86_64.tar.xz)
            printf '%s\n' "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_shellcheck_archive() {
    local expected_sha256=""
    local actual_sha256=""

    expected_sha256="$(shellcheck_expected_sha256)" || {
        printf "missing SHA256 for %s; set SHELLCHECK_SHA256 explicitly to install this asset\n" "$asset" >&2
        return 1
    }
    actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf "checksum mismatch for %s\n" "$asset" >&2
        printf "expected: %s\n" "$expected_sha256" >&2
        printf "actual:   %s\n" "$actual_sha256" >&2
        return 1
    fi
}

mkdir -p "$DOWNLOAD_DIR" "$SHELLCHECK_DIR"
curl -fL "$download_url" -o "$archive_path"
verify_shellcheck_archive
tar -xJf "$archive_path" -C "$DOWNLOAD_DIR"

# The tarball's top-level directory name is whatever upstream packaged it as
# (historically just "shellcheck-$VERSION", not the per-platform asset
# filename) -- read it from the archive instead of guessing, so a
# naming-convention change upstream can't silently break this.
extracted_dir="$(tar -tJf "$archive_path" | head -1 | cut -d/ -f1)"
if [ -z "$extracted_dir" ] || [ ! -x "$DOWNLOAD_DIR/$extracted_dir/shellcheck" ]; then
    printf "could not locate extracted shellcheck binary under %s (expected top-level dir %s)\n" \
        "$DOWNLOAD_DIR" "${extracted_dir:-<unknown>}" >&2
    exit 1
fi
cp "$DOWNLOAD_DIR/$extracted_dir/shellcheck" "$SHELLCHECK_DIR/shellcheck"
chmod +x "$SHELLCHECK_DIR/shellcheck"

"$SHELLCHECK_DIR/shellcheck" --version
