#!/bin/bash
#
# Build, notarize and package a distributable AgInOl.app, then refresh the
# update manifests. Every value in the manifests is derived from the artifact
# this script produces — see Distribution/RELEASE_AUTOMATION.md.
#
# Usage:
#   Distribution/scripts/build_release.sh
#
# Environment:
#   NOTARY_PROFILE   notarytool keychain profile name (default: AgInOl)
#   SKIP_NOTARIZE=1  build and package without notarizing (local test only)
#   SKIP_UPLOAD=1    default; uploading is left to the release lane
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRIBUTION_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(dirname "$DISTRIBUTION_DIR")"
RELEASES_DIR="$DISTRIBUTION_DIR/releases"
NOTES_DIR="$DISTRIBUTION_DIR/release-notes"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AgInOl}"

SCHEME="AgInOl"
ARCHIVE_PATH="$BUILD_DIR/AgInOl.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/AgInOl.app"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR"

log "Archiving $SCHEME"
xcodebuild archive \
    -project "$PROJECT_DIR/AgInOl.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    | tail -20

log "Exporting Developer ID build"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$DISTRIBUTION_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_PATH" \
    | tail -20

[ -d "$APP_PATH" ] || { echo "Export produced no app at $APP_PATH" >&2; exit 1; }

plist="$APP_PATH/Contents/Info.plist"
short_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")"
release_name="AgInOl-${short_version}-${build_number}"
zip_path="$RELEASES_DIR/${release_name}.zip"

log "Packaging $release_name"

if [ -e "$zip_path" ]; then
    cat >&2 <<EOF
$zip_path already exists.

A published build must never be replaced — clients verify a signature over the
exact bytes. Bump CURRENT_PROJECT_VERSION (e.g. 'agvtool next-version -all')
and build again, or delete the zip if it was never published.
EOF
    exit 1
fi

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    log "SKIP_NOTARIZE=1 — packaging an un-notarized build (not distributable)"
else
    notarize_zip="$BUILD_DIR/${release_name}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$notarize_zip"

    log "Submitting to notarytool (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$notarize_zip" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    log "Stapling ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

# Zip the stapled app: this is the archive Sparkle signs and ships.
ditto -c -k --keepParent "$APP_PATH" "$zip_path"

# Release notes are the one hand-written input. Sparkle picks up an .html file
# sitting next to the archive under the same base name.
notes_source="$NOTES_DIR/${short_version}.html"
if [ -f "$notes_source" ]; then
    cp "$notes_source" "$RELEASES_DIR/${release_name}.html"
else
    echo "warning: no release notes at $notes_source — the feed item will have no description" >&2
fi

log "Refreshing manifests"
"$SCRIPT_DIR/update_manifest.sh"

log "Done: $zip_path"
echo
echo "Next:"
echo "  1. Upload $zip_path and Distribution/appcast.xml + aginol.json to the download area."
echo "  2. Commit the regenerated manifests."
