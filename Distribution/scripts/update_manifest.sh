#!/bin/bash
#
# Regenerate the update manifests from the archives in Distribution/releases.
#
# This is a pure function of that folder: it reads every zip, takes version,
# build number and minimum system version from the Info.plist inside, signs the
# archives with the EdDSA key, and writes the complete feed. Running it twice
# produces the same output; running it after deleting a zip retracts that
# release. Nothing here needs the network.
#
# Usage:
#   Distribution/scripts/update_manifest.sh
#
# Environment:
#   DOWNLOAD_URL_PREFIX      where the zips will be reachable
#   SPARKLE_BIN              folder holding generate_appcast (autodetected)
#   SPARKLE_PRIVATE_KEY_FILE EdDSA key file for CI; omit to use the Keychain
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRIBUTION_DIR="$(dirname "$SCRIPT_DIR")"
RELEASES_DIR="$DISTRIBUTION_DIR/releases"
APPCAST_PATH="$DISTRIBUTION_DIR/appcast.xml"
JSON_PATH="$DISTRIBUTION_DIR/aginol.json"

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://aiia.li/downloads/}"
APPCAST_URL="${APPCAST_URL:-https://aiia.li/downloads/aginol_appcast.xml}"

find_generate_appcast() {
    if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
        echo "$SPARKLE_BIN/generate_appcast"
        return
    fi
    if command -v generate_appcast >/dev/null 2>&1; then
        command -v generate_appcast
        return
    fi
    # Sparkle ships its tools inside the SwiftPM binary artifact.
    local candidate
    candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type f -name generate_appcast -path "*artifacts*" 2>/dev/null | head -1)"
    [ -n "$candidate" ] && echo "$candidate"
}

shopt -s nullglob
archives=("$RELEASES_DIR"/*.zip)
shopt -u nullglob
if [ ${#archives[@]} -eq 0 ]; then
    echo "No archives in $RELEASES_DIR — nothing to publish." >&2
    exit 1
fi

GENERATE_APPCAST="$(find_generate_appcast || true)"
if [ -z "$GENERATE_APPCAST" ]; then
    cat >&2 <<'EOF'
generate_appcast not found.

It ships with Sparkle. Either build the app once so SwiftPM fetches the binary
artifact, download the Sparkle release tarball and point SPARKLE_BIN at its
bin/ folder, or `brew install --cask sparkle`.
EOF
    exit 1
fi

args=(
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
    --link "$APPCAST_URL"
    -o "$APPCAST_PATH"
)
[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ] && args+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")

echo "==> generate_appcast ($(basename "$GENERATE_APPCAST")) over ${#archives[@]} archive(s)"
"$GENERATE_APPCAST" "${args[@]}" "$RELEASES_DIR"

echo "==> projecting newest item into $(basename "$JSON_PATH")"
python3 "$SCRIPT_DIR/appcast_to_json.py" \
    --appcast "$APPCAST_PATH" \
    --releases "$RELEASES_DIR" \
    --appcast-url "$APPCAST_URL" \
    --output "$JSON_PATH"

echo "==> manifests updated"
