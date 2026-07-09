#!/usr/bin/env bash

set -Eeuo pipefail

readonly VENDOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUSTUP_URL="${RUSTUP_URL:-https://sh.rustup.rs}"
readonly MINICONDA_URL="${MINICONDA_URL:-https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh}"
readonly RUSTUP_INSTALLER="$VENDOR_DIR/rustup-init.sh"
readonly MINICONDA_INSTALLER="$VENDOR_DIR/Miniconda3-latest-Linux-x86_64.sh"

download_file() {
    local url="$1"
    local destination="$2"
    local tmp

    tmp="$(mktemp "${destination}.tmp.XXXXXX")"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp" "$url"
    chmod 755 "$tmp"
    mv -f "$tmp" "$destination"
}

if ! command -v curl >/dev/null 2>&1; then
    echo "curl was not found. Install curl first." >&2
    exit 1
fi

echo "Downloading Rust installer:"
echo "  $RUSTUP_URL"
download_file "$RUSTUP_URL" "$RUSTUP_INSTALLER"

echo "Downloading Miniconda installer:"
echo "  $MINICONDA_URL"
download_file "$MINICONDA_URL" "$MINICONDA_INSTALLER"

echo
echo "Downloaded installers:"
printf '  %s\n' "$RUSTUP_INSTALLER"
printf '  %s\n' "$MINICONDA_INSTALLER"
