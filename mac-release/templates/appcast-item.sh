#!/usr/bin/env zsh
# Emit a ready-to-paste Sparkle <item> for a built DMG.
#
# Every attribute is derived from the artifact itself — the app's
# CFBundleShortVersionString and CFBundleVersion are read from the bundle
# *inside* the DMG, the length is the DMG's byte count, and the EdDSA signature
# is computed over the DMG. Nothing is hand-typed, so sparkle:version /
# sparkle:shortVersionString / length / edSignature can never drift from the
# artifact they describe.
#
# Why this exists: a real release shipped with a hand-typed sparkle:version one
# off from the DMG's actual CFBundleVersion, AND a marketing version that was
# never bumped (the bundle reported the previous version inside a DMG named for
# the new one). Sparkle compares CFBundleVersion for the update *decision* but
# prints the marketing strings in its *dialog*, so clients saw "You're up to
# date" naming the new version as newest while reporting they ran the old one.
# Generating the item from the artifact makes both drifts impossible. See
# references/versioning.md.
#
# This is a TEMPLATE. Edit the CONFIG block. release.sh calls this at the end of
# every run; you can also run it standalone against any built DMG.
#
# Usage:
#   scripts/appcast-item.sh dist/<APP>-<sha>.dmg

set -euo pipefail

# ---- CONFIG — edit for your app -------------------------------------------
APP_NAME="MyApp"
SPARKLE_ACCOUNT="MyApp"                       # must match generate_keys --account
DOWNLOAD_URL_BASE="https://updates.example.com/downloads"   # <base>/<APP>-<X.Y.Z>.dmg
RELEASE_NOTES_BASE="https://updates.example.com/changelog.html"  # appends #vX-Y-Z
BUILD_XCCONFIG_REL="Configuration/Build.xcconfig"   # read MACOSX_DEPLOYMENT_TARGET
DEFAULT_MIN_SYSTEM="14.0"
# Glob(s) where Sparkle's sign_update may live after a build resolves the
# package. The (N) makes a non-matching glob expand to nothing instead of error.
SIGN_UPDATE_CANDIDATES=(
    "$HOME/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
)
# --------------------------------------------------------------------------

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    print -u2 "usage: scripts/appcast-item.sh <path/to/${APP_NAME}-*.dmg>"
    exit 2
fi

MIN_SYSTEM=$(grep -E '^MACOSX_DEPLOYMENT_TARGET' "$REPO_ROOT/$BUILD_XCCONFIG_REL" \
    2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
MIN_SYSTEM="${MIN_SYSTEM:-$DEFAULT_MIN_SYSTEM}"

# Locate sign_update — it ships as an SPM artifact under DerivedData (Xcode) or
# the package's .build (CLI swift build). Add candidates above as needed.
find_sign_update() {
    local c
    for c in ${~SIGN_UPDATE_CANDIDATES}; do
        [[ -x "$c" ]] && { print -r -- "$c"; return 0 }
    done
    return 1
}

SIGN_UPDATE=$(find_sign_update) || {
    print -u2 "error: sign_update not found. Build the app once so the Sparkle SPM"
    print -u2 "       artifacts are produced, then retry. Adjust SIGN_UPDATE_CANDIDATES."
    exit 1
}

# Read the version fields from the app bundle inside the DMG. Mount read-only,
# no-browse, on a random mountpoint; always detach on exit.
MOUNT_DIR=$(hdiutil attach "$DMG" -nobrowse -readonly -mountrandom /tmp \
    | awk '/\/tmp\// {print $NF; exit}')
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    print -u2 "error: failed to mount $DMG"
    exit 1
fi
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true' EXIT

APP=$(print -r -- "$MOUNT_DIR"/*.app(N) | head -1)
if [[ -z "$APP" || ! -d "$APP" ]]; then
    print -u2 "error: no .app found inside $DMG"
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")

if [[ -z "$SHORT_VERSION" || -z "$BUILD_VERSION" ]]; then
    print -u2 "error: could not read version fields from $PLIST"
    exit 1
fi

# sign_update prints: sparkle:edSignature="..." length="..."
SIG_LINE=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG")
ED_SIGNATURE=$(print -r -- "$SIG_LINE" | grep -oE 'sparkle:edSignature="[^"]+"' | sed -E 's/.*="([^"]+)"/\1/')
LENGTH=$(print -r -- "$SIG_LINE" | grep -oE 'length="[0-9]+"' | sed -E 's/.*="([0-9]+)"/\1/')

if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
    print -u2 "error: sign_update output not understood:"
    print -u2 "       $SIG_LINE"
    print -u2 "       (Is --account '$SPARKLE_ACCOUNT' the name used with generate_keys?)"
    exit 1
fi

# Cross-check length against the actual file size.
ACTUAL_BYTES=$(stat -f '%z' "$DMG")
if [[ "$LENGTH" != "$ACTUAL_BYTES" ]]; then
    print -u2 "error: sign_update length ($LENGTH) != DMG byte size ($ACTUAL_BYTES)"
    exit 1
fi

ANCHOR="v${SHORT_VERSION//./-}"
PUBDATE=$(date -u +"%a, %d %b %Y 00:00:00 +0000")

cat <<EOF
    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_BASE}#${ANCHOR}</sparkle:releaseNotesLink>
      <description><![CDATA[
        TODO: paste user-visible release notes for ${SHORT_VERSION} here.
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL_BASE}/${APP_NAME}-${SHORT_VERSION}.dmg"
        sparkle:version="${BUILD_VERSION}"
        sparkle:shortVersionString="${SHORT_VERSION}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${LENGTH}"
        type="application/octet-stream" />
    </item>
EOF

print -u2 ""
print -u2 "Generated <item> for ${APP_NAME} ${SHORT_VERSION} (build ${BUILD_VERSION})."
print -u2 "  - Paste it as the FIRST <item> in appcast.xml (newest first)."
print -u2 "  - Copy the DMG to your downloads dir as ${APP_NAME}-${SHORT_VERSION}.dmg."
print -u2 "  - Fill in the <description> release notes."
