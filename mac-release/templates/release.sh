#!/usr/bin/env zsh
# Build, sign, notarize, staple, and package <APP>.app for distribution.
#
# Produces dist/<APP>-<sha>.dmg with a drag-to-Applications layout, signed with
# Developer ID and notarized so Gatekeeper accepts it on first launch — no
# right-click bypass, no "unidentified developer" warning.
#
# This is a TEMPLATE. Copy it into your app's scripts/ directory and edit the
# CONFIG block below. The flow below is battle-tested; the comments explain the
# non-obvious bits (why name==volname, why build/ is torn down, etc.) — keep them.

set -euo pipefail

# ---- CONFIG — edit for your app -------------------------------------------
APP_NAME="MyApp"                              # bundle/product name (no .app)
SCHEME="MyApp"                                # xcodebuild scheme to archive
TEAM_ID="XXXXXXXXXX"                          # Apple Developer Team ID
SIGN_IDENTITY="Developer ID Application: Your Name ($TEAM_ID)"
NOTARY_PROFILE="MyApp-notary"                 # notarytool keychain profile (see setup-notary.sh)
# Path to the .xcodeproj OR .xcworkspace, relative to repo root.
PROJECT_REL="MyApp.xcodeproj"
# Holds MARKETING_VERSION — used for the version-consistency gate below.
APP_XCCONFIG_REL="Configuration/App.xcconfig"
# --------------------------------------------------------------------------

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
PROJECT="$REPO_ROOT/$PROJECT_REL"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/Export"
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"

# Pass -project or -workspace depending on what PROJECT_REL points at.
if [[ "$PROJECT_REL" == *.xcworkspace ]]; then
    PROJECT_FLAG=(-workspace "$PROJECT")
else
    PROJECT_FLAG=(-project "$PROJECT")
fi

# --- Preflight ---------------------------------------------------------------

if [[ ! -e "$PROJECT" ]]; then
    print -u2 "error: $PROJECT not found"
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    print -u2 "error: create-dmg not installed. Run: brew install create-dmg"
    exit 1
fi

if ! command -v fileicon >/dev/null 2>&1; then
    print -u2 "error: fileicon not installed. Run: brew install fileicon"
    exit 1
fi

if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    print -u2 "error: signing identity not found in Keychain:"
    print -u2 "       $SIGN_IDENTITY"
    print -u2 "       Add via Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    print -u2 "error: notarytool keychain profile '$NOTARY_PROFILE' missing or invalid."
    print -u2 "       Set it up with scripts/setup-notary.sh"
    exit 1
fi

# --- Build & export ----------------------------------------------------------

print "==> Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# Build number = today's UTC date in YYYYMMDD. This is the monotonically
# increasing integer Sparkle compares (CFBundleVersion). Do NOT bump it by
# hand — overriding it here keeps it deterministic and ahead of the last
# release. Same-day re-releases collide (Sparkle sees "no newer build"); if you
# must re-cut on the same day, switch to date -u +%Y%m%d%H%M for this one run.
BUILD_NUMBER="$(date -u +%Y%m%d)"
print "==> Build number for this release: $BUILD_NUMBER"

print "==> Writing export options plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

print "==> Archiving Release"
xcodebuild archive \
    "${PROJECT_FLAG[@]}" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

print "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "error: exported app not found at $APP_PATH"
    exit 1
fi

print "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Version-consistency gate: confirm the *built* bundle carries the versions we
# expect before it gets packaged and notarized. Two failure modes this catches —
# both produced a real "You're up to date" bug (see references/versioning.md):
#   - CFBundleShortVersionString != MARKETING_VERSION — a per-target pbxproj
#     override or stale build setting won and the marketing version drifted
#     (the app shipped reporting the *previous* version).
#   - CFBundleVersion != the build number we injected — the archive didn't honor
#     CURRENT_PROJECT_VERSION, so Sparkle's comparison key would be wrong.
# Failing here is cheap; discovering it in users' update dialogs is not.
EXPECTED_SHORT=$(grep -E '^MARKETING_VERSION' "$REPO_ROOT/$APP_XCCONFIG_REL" \
    | head -1 | awk -F= '{print $2}' | tr -d ' ')
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [[ "$ACTUAL_SHORT" != "$EXPECTED_SHORT" ]]; then
    print -u2 "error: built CFBundleShortVersionString ($ACTUAL_SHORT) != MARKETING_VERSION ($EXPECTED_SHORT)"
    print -u2 "       The bundle's marketing version drifted from $APP_XCCONFIG_REL. Check for a"
    print -u2 "       per-target MARKETING_VERSION override in project.pbxproj (the preflight flags this)."
    exit 1
fi
if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    print -u2 "error: built CFBundleVersion ($ACTUAL_BUILD) != injected build number ($BUILD_NUMBER)"
    print -u2 "       The archive did not honor CURRENT_PROJECT_VERSION=$BUILD_NUMBER."
    exit 1
fi
print "==> Version check: $ACTUAL_SHORT (build $ACTUAL_BUILD) matches $APP_XCCONFIG_REL + build number"

# AppIcon.icns is generated from Assets.xcassets/AppIcon.appiconset during the
# build and lives inside the bundle. It drives both the mounted volume's Finder
# icon (--volicon) and the .dmg file's own Finder icon (fileicon, after staple).
APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
if [[ ! -f "$APP_ICON" ]]; then
    print -u2 "error: AppIcon.icns not found at $APP_ICON"
    exit 1
fi

# --- DMG ---------------------------------------------------------------------

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)"

# Build/sign/notarize/staple all run against a fixed-name DMG that matches the
# volume name. Reason: when the DMG filename and --volname differ, macOS
# (Gatekeeper provenance handling, observed during the notarytool roundtrip) can
# silently rename the file on disk to match the volume — breaking the next step.
# Keep name == volname through the pipeline; tag with the git sha by renaming
# ONCE, after stapling completes.
WORK_DMG="$DIST_DIR/$APP_NAME.dmg"
DMG_PATH="$DIST_DIR/$APP_NAME-$GIT_SHA.dmg"

print "==> Creating DMG: $WORK_DMG"
rm -f "$WORK_DMG" "$DMG_PATH"
create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP_ICON" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 175 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    "$WORK_DMG" \
    "$APP_PATH"

print "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$WORK_DMG"

# --- Notarize ----------------------------------------------------------------

print "==> Submitting for notarization (this can take several minutes)"
xcrun notarytool submit "$WORK_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

print "==> Stapling notarization ticket"
xcrun stapler staple "$WORK_DMG"
xcrun stapler validate "$WORK_DMG"

print "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -vv "$WORK_DMG"

print "==> Tagging final artifact with git sha"
mv "$WORK_DMG" "$DMG_PATH"

# Set the DMG file's Finder icon to the app icon. fileicon writes only to
# extended attributes (com.apple.ResourceFork + com.apple.FinderInfo) and leaves
# the disk image's data fork untouched, so the codesign signature and stapled
# notarization ticket on the .dmg remain valid.
print "==> Setting DMG file icon"
fileicon set "$DMG_PATH" "$APP_ICON"

# --- Cleanup -----------------------------------------------------------------

# Tear down build/ after the DMG is produced. Reason: leaving a Release .app in
# build/ means LaunchServices indexes it alongside the Debug build Xcode runs
# from DerivedData. Both share the same bundle id, and tapping a notification
# can route to either — producing two dock icons. Removing the .app keeps the
# DMG as the one canonical distributable.
print "==> Cleaning up build artifacts ($BUILD_DIR)"
rm -rf "$BUILD_DIR"

print
print "Done. Distributable at:"
print "  $DMG_PATH"
print "  Build number: $BUILD_NUMBER"
print

# Emit a ready-to-paste appcast <item> derived from the artifact itself, so
# sparkle:version / sparkle:shortVersionString / length / edSignature can never
# be hand-typed out of sync with the DMG. Best-effort: if the Sparkle signing
# key isn't on this machine the release still succeeded — run appcast-item.sh
# later. See references/appcast.md and references/versioning.md.
print "==> Appcast item for appcast.xml (paste as the first <item>):"
print
if ! "$SCRIPT_DIR/appcast-item.sh" "$DMG_PATH"; then
    print -u2 "note: could not auto-generate the appcast item; run scripts/appcast-item.sh \"$DMG_PATH\" manually."
fi
print
print "On the recipient's Mac:"
print "  - Double-click the DMG"
print "  - Drag $APP_NAME.app onto the Applications shortcut"
print "  - Launch from Applications — no Gatekeeper warning, no right-click bypass"
