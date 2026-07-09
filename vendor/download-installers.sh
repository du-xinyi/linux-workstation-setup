#!/usr/bin/env bash

set -Eeuo pipefail

readonly VENDOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUSTUP_URL="${RUSTUP_URL:-https://sh.rustup.rs}"
readonly MINICONDA_URL="${MINICONDA_URL:-https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh}"
readonly RUSTUP_INSTALLER="$VENDOR_DIR/rustup-init.sh"
readonly MINICONDA_INSTALLER="$VENDOR_DIR/Miniconda3-latest-Linux-x86_64.sh"
targets=("$@")

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

if [ "${#targets[@]}" -eq 0 ]; then
    targets=(all)
fi

for target in "${targets[@]}"; do
    case "$target" in
        all)
            "$0" rust miniconda
            exit
            ;;
        rust)
            echo "Downloading Rust installer:"
            echo "  $RUSTUP_URL"
            download_file "$RUSTUP_URL" "$RUSTUP_INSTALLER"
            ;;
        miniconda)
            echo "Downloading Miniconda installer:"
            echo "  $MINICONDA_URL"
            download_file "$MINICONDA_URL" "$MINICONDA_INSTALLER"
            ;;
        *)
            echo "Unknown installer target: $target" >&2
            echo "Usage: ./vendor/download-installers.sh [rust|miniconda|all]..." >&2
            exit 2
            ;;
    esac
done

echo
echo "Downloaded installers:"
for target in "${targets[@]}"; do
    case "$target" in
        rust)      printf '  %s\n' "$RUSTUP_INSTALLER" ;;
        miniconda) printf '  %s\n' "$MINICONDA_INSTALLER" ;;
    esac
done
