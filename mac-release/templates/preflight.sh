#!/usr/bin/env zsh
# Walk the release-readiness gates. Read-only — never mutates anything.
#
# This is a TEMPLATE. Copy into scripts/, edit the CONFIG block, and delete or
# add gates to match your project. The gate machinery (pass/fail/warn, --strict)
# is generic; the individual checks encode the lessons from one app's releases —
# keep the ones that apply, drop the rest.
#
# Each gate prints one line:
#   [✓] description           — passing
#   [✗] description           — failing (causes non-zero exit)
#   [!] description           — warning (zero exit unless --strict)
#
# Flags:
#   --strict             warnings become failures
#   --allow-dirty        skip the "working tree clean" failure
#   --allow-no-sparkle   skip the Sparkle plist/key checks
#   --skip-ssh-check     don't actually SSH to the deploy host
#   --skip-build         don't re-run xcodebuild / tests (faster ad-hoc check)
#   -h | --help          this help

set -uo pipefail

# ---- CONFIG — edit for your app -------------------------------------------
APP_NAME="MyApp"
SCHEME="MyApp"                                   # scheme for the build gate
PROJECT_REL="MyApp.xcworkspace"                  # .xcodeproj or .xcworkspace
APP_XCCONFIG_REL="Configuration/App.xcconfig"    # holds MARKETING_VERSION, SU_* keys
BUILD_XCCONFIG_REL="Configuration/Build.xcconfig" # holds DEVELOPMENT_TEAM
PBXPROJ_REL="MyApp.xcodeproj/project.pbxproj"
APPCAST_REL="website/appcast.xml"                # set to "" if you have no appcast yet
DOWNLOADS_DIR_REL="website/downloads"            # where published DMGs live (for the consistency gate)
WEBSITE_INDEX_REL="website/index.html"           # set to "" to skip website gates
NOTARY_PROFILE="MyApp-notary"
# Deploy env-var names (see deploy-website.sh). Leave as-is or rename per app.
DEPLOY_HOST_VAR="DEPLOY_HOST"
DEPLOY_PATH_VAR="DEPLOY_PATH"
DEPLOY_KEY_VAR="DEPLOY_KEY"
DEPLOY_PORT_VAR="DEPLOY_PORT"
# Run unit tests in the build gate? Set the test action, or "" to skip.
#   xcodebuild workspace example:  TEST_CMD=(xcodebuild test -workspace ... -scheme ... -only-testing:MyAppTests)
TEST_CMD=()
# --------------------------------------------------------------------------

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
APP_XCCONFIG="$REPO_ROOT/$APP_XCCONFIG_REL"
BUILD_XCCONFIG="$REPO_ROOT/$BUILD_XCCONFIG_REL"
PBXPROJ="$REPO_ROOT/$PBXPROJ_REL"
PROJECT="$REPO_ROOT/$PROJECT_REL"
APPCAST="${APPCAST_REL:+$REPO_ROOT/$APPCAST_REL}"

if [[ "$PROJECT_REL" == *.xcworkspace ]]; then
    PROJECT_FLAG=(-workspace "$PROJECT")
else
    PROJECT_FLAG=(-project "$PROJECT")
fi

STRICT=0
ALLOW_DIRTY=0
ALLOW_NO_SPARKLE=0
SKIP_SSH=0
SKIP_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --allow-no-sparkle) ALLOW_NO_SPARKLE=1 ;;
        --skip-ssh-check) SKIP_SSH=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed '/^set -uo/d' | sed 's/^# *//'
            exit 0
            ;;
        *) print -u2 "preflight: unknown flag $arg"; exit 2 ;;
    esac
done

FAILS=0
WARNS=0

pass() { print "  [✓] $1"; }
fail() { print "  [✗] $1"; FAILS=$((FAILS + 1)); }
warn() {
    if (( STRICT )); then
        print "  [✗] $1 (strict)"; FAILS=$((FAILS + 1))
    else
        print "  [!] $1"; WARNS=$((WARNS + 1))
    fi
}

section() { print ""; print "$1"; }

# Compare two dotted versions (ignoring any -prerelease suffix).
# Prints 1 if $1 > $2, -1 if $1 < $2, 0 if equal.
ver_cmp() {
    local a=${1%%-*} b=${2%%-*}
    local -a A B
    A=(${(s:.:)a}); B=(${(s:.:)b})
    local i x y
    for i in 1 2 3; do
        x=${A[i]:-0}; y=${B[i]:-0}
        (( x > y )) && { print 1; return }
        (( x < y )) && { print -- -1; return }
    done
    print 0
}

# First (newest) value of an attribute in the appcast. Convention is
# newest-item-first, so head -1 is the newest release. XML comments are stripped
# first so placeholder text in an authoring comment (e.g. length="...") can't be
# mistaken for a real attribute.
appcast_newest_attr() {
    perl -0777 -pe 's/<!--.*?-->//gs' "$APPCAST" 2>/dev/null \
        | grep -oE "$1=\"[^\"]+\"" | head -1 | sed -E 's/.*="([^"]+)"/\1/'
}

# --- Build gates -------------------------------------------------------------

section "Build gates"

if (( SKIP_BUILD )); then
    pass "build/test skipped (--skip-build)"
else
    if xcodebuild "${PROJECT_FLAG[@]}" -scheme "$SCHEME" -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build >/tmp/${APP_NAME}-preflight-build.log 2>&1; then
        pass "xcodebuild build"
    else
        fail "xcodebuild build (see /tmp/${APP_NAME}-preflight-build.log)"
    fi

    if (( ${#TEST_CMD[@]} )); then
        if "${TEST_CMD[@]}" >/tmp/${APP_NAME}-preflight-test.log 2>&1; then
            pass "tests"
        else
            fail "tests (see /tmp/${APP_NAME}-preflight-test.log)"
        fi
    fi
fi

# --- Version gates -----------------------------------------------------------

section "Version gates"

VERSION=$(grep -E '^MARKETING_VERSION' "$APP_XCCONFIG" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

if [[ -z "$VERSION" ]]; then
    fail "MARKETING_VERSION missing from $APP_XCCONFIG_REL"
else
    pass "MARKETING_VERSION = $VERSION ($APP_XCCONFIG_REL)"
fi

# xcconfig is the single source of truth for the version. A per-target
# MARKETING_VERSION in pbxproj silently wins at build time, so its presence is a
# drift hazard — fail on it.
if [[ -f "$PBXPROJ" ]] && grep -qE 'MARKETING_VERSION = ' "$PBXPROJ"; then
    DISTINCT=$(grep -E 'MARKETING_VERSION = ' "$PBXPROJ" | awk -F'= ' '{print $2}' | tr -d ' ;' | sort -u)
    fail "pbxproj contains MARKETING_VERSION ($DISTINCT) — should live only in $APP_XCCONFIG_REL"
else
    pass "pbxproj has no MARKETING_VERSION override (xcconfig wins)"
fi

if [[ -f "$PBXPROJ" ]] && grep -qE 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ"; then
    fail "pbxproj contains CURRENT_PROJECT_VERSION — release.sh sets it at archive time"
else
    pass "pbxproj has no CURRENT_PROJECT_VERSION override"
fi

# SemVer-ish sanity (X.Y.Z plus optional -prerelease).
if [[ -n "$VERSION" ]]; then
    if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
        pass "MARKETING_VERSION matches SemVer"
    else
        warn "MARKETING_VERSION '$VERSION' is not strict X.Y.Z"
    fi
fi

# Build-number collision gate. release.sh derives CURRENT_PROJECT_VERSION as
# today's YYYYMMDD. A same-day re-release produces an identical build number to
# the last one, which Sparkle treats as "no update available". Compare today's
# UTC date against the highest sparkle:version already published.
TODAY_BUILD="$(date -u +%Y%m%d)"
if [[ -n "$APPCAST" && -f "$APPCAST" ]]; then
    HIGHEST_BUILD=$(grep -oE 'sparkle:version="[0-9]+"' "$APPCAST" 2>/dev/null \
        | grep -oE '[0-9]+' | sort -rn | head -1)
    if [[ -z "$HIGHEST_BUILD" ]]; then
        pass "appcast has no prior sparkle:version (first release)"
    elif [[ "$HIGHEST_BUILD" -lt "$TODAY_BUILD" ]]; then
        pass "today's build $TODAY_BUILD > highest in appcast ($HIGHEST_BUILD)"
    elif [[ "$HIGHEST_BUILD" -eq "$TODAY_BUILD" ]]; then
        warn "today's YYYYMMDD ($TODAY_BUILD) already in appcast — same-day re-release would collide; use date -u +%Y%m%d%H%M for this build"
    else
        fail "appcast has sparkle:version $HIGHEST_BUILD > today's $TODAY_BUILD (clock skew or stale appcast)"
    fi
elif [[ -n "$APPCAST" ]]; then
    warn "$APPCAST_REL not found — skipping build-number collision check"
fi

# Marketing-version bump gate. The most common release mistake is forgetting to
# bump MARKETING_VERSION, so the new build ships with the same marketing version
# as the last release. Sparkle compares CFBundleVersion for the update decision
# but prints the marketing strings in its dialog — a stale MARKETING_VERSION
# makes a user on the new build see "you're up to date, running <old version>".
# MARKETING_VERSION must be strictly greater than the newest version already
# advertised in the appcast. See references/versioning.md.
if [[ -n "$APPCAST" && -f "$APPCAST" && -n "$VERSION" ]]; then
    NEWEST_SHORT=$(appcast_newest_attr 'sparkle:shortVersionString')
    if [[ -z "$NEWEST_SHORT" ]]; then
        pass "appcast has no prior shortVersionString (first release)"
    else
        case "$(ver_cmp "$VERSION" "$NEWEST_SHORT")" in
            1)  pass "MARKETING_VERSION $VERSION > newest released $NEWEST_SHORT" ;;
            0)  fail "MARKETING_VERSION ($VERSION) equals the newest released version — bump it before release" ;;
            *)  fail "MARKETING_VERSION ($VERSION) is older than the newest released $NEWEST_SHORT" ;;
        esac
    fi
fi

# Appcast <-> DMG consistency gate. The advertised attributes must match the
# artifact they point at. The newest item's DMG, if present locally, is mounted
# read-only and its real version fields + byte length are compared to the
# sparkle:* attributes — a mismatch is exactly the drift that ships a broken
# update feed. Warn-level: already-published items are historical, and the hard
# guarantee lives in release.sh + appcast-item.sh. --strict promotes to failure.
if [[ -n "$APPCAST" && -f "$APPCAST" ]]; then
    A_SHORT=$(appcast_newest_attr 'sparkle:shortVersionString')
    A_BUILD=$(appcast_newest_attr 'sparkle:version')
    A_LENGTH=$(appcast_newest_attr 'length')
    DMG_LOCAL="$REPO_ROOT/$DOWNLOADS_DIR_REL/$APP_NAME-$A_SHORT.dmg"
    if [[ -z "$A_SHORT" ]]; then
        pass "appcast has no items to cross-check"
    elif [[ ! -f "$DMG_LOCAL" ]]; then
        warn "newest appcast item is $A_SHORT but $DOWNLOADS_DIR_REL/$APP_NAME-$A_SHORT.dmg is absent — cannot cross-check"
    else
        BYTES=$(stat -f '%z' "$DMG_LOCAL")
        if [[ "$BYTES" == "$A_LENGTH" ]]; then
            pass "appcast length matches $APP_NAME-$A_SHORT.dmg ($BYTES bytes)"
        else
            warn "appcast length ($A_LENGTH) != $APP_NAME-$A_SHORT.dmg byte size ($BYTES)"
        fi
        MP=$(hdiutil attach "$DMG_LOCAL" -nobrowse -readonly -mountrandom /tmp 2>/dev/null \
            | awk '/\/tmp\// {print $NF; exit}')
        if [[ -n "$MP" && -d "$MP" ]]; then
            APP_IN=$(print -r -- "$MP"/*.app(N) | head -1)
            if [[ -n "$APP_IN" ]]; then
                D_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_IN/Contents/Info.plist" 2>/dev/null)
                D_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_IN/Contents/Info.plist" 2>/dev/null)
                if [[ "$D_SHORT" == "$A_SHORT" ]]; then
                    pass "DMG CFBundleShortVersionString matches appcast ($A_SHORT)"
                else
                    warn "DMG CFBundleShortVersionString ($D_SHORT) != appcast sparkle:shortVersionString ($A_SHORT)"
                fi
                if [[ "$D_BUILD" == "$A_BUILD" ]]; then
                    pass "DMG CFBundleVersion matches appcast ($A_BUILD)"
                else
                    warn "DMG CFBundleVersion ($D_BUILD) != appcast sparkle:version ($A_BUILD)"
                fi
            else
                warn "no .app inside $APP_NAME-$A_SHORT.dmg — cannot verify versions"
            fi
            hdiutil detach "$MP" -quiet 2>/dev/null || true
        else
            warn "could not mount $APP_NAME-$A_SHORT.dmg to cross-check versions"
        fi
    fi
fi

# --- Sparkle gates -----------------------------------------------------------

section "Sparkle gates"

if (( ALLOW_NO_SPARKLE )); then
    pass "Sparkle checks skipped (--allow-no-sparkle)"
else
    # Source of truth: App.xcconfig. Info.plist references $(SU_FEED_URL) /
    # $(SU_PUBLIC_ED_KEY), so checking the xcconfig is enough and doesn't need a
    # recent build.
    SU_FEED=$(grep -E '^SU_FEED_URL' "$APP_XCCONFIG" 2>/dev/null \
        | head -1 | awk -F'=' '{sub(/^[ \t]+/, "", $2); print $2}')
    if [[ -n "$SU_FEED" ]]; then
        pass "SU_FEED_URL set in $APP_XCCONFIG_REL: $SU_FEED"
    else
        fail "SU_FEED_URL missing from $APP_XCCONFIG_REL"
    fi

    SU_KEY=$(grep -E '^SU_PUBLIC_ED_KEY' "$APP_XCCONFIG" 2>/dev/null \
        | head -1 | awk -F'=' '{sub(/^[ \t]+/, "", $2); print $2}')
    if [[ -n "$SU_KEY" && "$SU_KEY" != PLACEHOLDER* ]]; then
        pass "SU_PUBLIC_ED_KEY set in $APP_XCCONFIG_REL"
    else
        warn "SU_PUBLIC_ED_KEY missing/placeholder — run Sparkle's generate_keys before release"
    fi
fi

# --- Release-pipeline gates --------------------------------------------------

section "Release-pipeline gates"

TEAM_ID=$(grep -E '^DEVELOPMENT_TEAM' "$BUILD_XCCONFIG" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
if [[ -n "$TEAM_ID" ]] && security find-identity -p codesigning -v 2>/dev/null \
    | grep -q "Developer ID Application.*$TEAM_ID"; then
    pass "Developer ID Application cert in keychain ($TEAM_ID)"
else
    warn "Developer ID Application cert not found for team $TEAM_ID (release.sh will fail)"
fi

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    pass "notarytool keychain profile '$NOTARY_PROFILE' configured"
else
    warn "notarytool '$NOTARY_PROFILE' keychain profile missing (run scripts/setup-notary.sh)"
fi

if command -v create-dmg >/dev/null 2>&1; then
    pass "create-dmg installed"
else
    warn "create-dmg not on PATH (brew install create-dmg)"
fi

if command -v fileicon >/dev/null 2>&1; then
    pass "fileicon installed"
else
    warn "fileicon not on PATH (brew install fileicon)"
fi

# --- Website gates -----------------------------------------------------------

if [[ -n "$WEBSITE_INDEX_REL" ]]; then
    section "Website gates"

    if [[ -s "$REPO_ROOT/$WEBSITE_INDEX_REL" ]]; then
        pass "$WEBSITE_INDEX_REL exists and is non-empty"
    else
        fail "$WEBSITE_INDEX_REL missing or empty"
    fi

    if [[ -n "$APPCAST" && -f "$APPCAST" ]]; then
        if xmllint --noout "$APPCAST" 2>/dev/null; then
            pass "$APPCAST_REL is valid XML"
        else
            fail "$APPCAST_REL fails XML validation"
        fi
    elif [[ -n "$APPCAST" ]]; then
        fail "$APPCAST_REL missing"
    fi

    DEPLOY_HOST="${(P)DEPLOY_HOST_VAR:-}"
    DEPLOY_PATH="${(P)DEPLOY_PATH_VAR:-}"
    DEPLOY_KEY="${(P)DEPLOY_KEY_VAR:-}"
    if [[ -n "$DEPLOY_HOST" && -n "$DEPLOY_PATH" ]]; then
        pass "deploy env vars exported ($DEPLOY_HOST_VAR / $DEPLOY_PATH_VAR)"

        if [[ -n "$DEPLOY_KEY" ]]; then
            if [[ -f "$DEPLOY_KEY" ]]; then
                KEY_PERMS=$(stat -f '%Lp' "$DEPLOY_KEY" 2>/dev/null || stat -c '%a' "$DEPLOY_KEY")
                if [[ "$KEY_PERMS" == "400" || "$KEY_PERMS" == "600" ]]; then
                    pass "deploy key has $KEY_PERMS perms"
                else
                    fail "deploy key $DEPLOY_KEY has $KEY_PERMS perms (need 400/600)"
                fi
            else
                fail "$DEPLOY_KEY_VAR points at $DEPLOY_KEY which does not exist"
            fi
        fi

        if (( SKIP_SSH )); then
            pass "SSH liveness skipped (--skip-ssh-check)"
        else
            PORT="${(P)DEPLOY_PORT_VAR:-22}"
            SSH_ARGS=(-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "$PORT")
            [[ -n "$DEPLOY_KEY" ]] && SSH_ARGS+=(-i "$DEPLOY_KEY")
            if ssh "${SSH_ARGS[@]}" "$DEPLOY_HOST" true 2>/dev/null; then
                pass "ssh to $DEPLOY_HOST works"
            else
                warn "ssh to $DEPLOY_HOST failed; deploy-website.sh will fail too"
            fi
        fi
    else
        pass "deploy env vars not set — manual upload path (deploy-website.sh disabled)"
    fi
fi

# --- Workspace gate ----------------------------------------------------------

section "Workspace gate"

DIRTY=$(git -C "$REPO_ROOT" status --porcelain)
if [[ -z "$DIRTY" ]]; then
    pass "working tree is clean"
else
    # During release prep the website/ tree is expected to be dirty (new appcast
    # item, new DMG copy, changelog). Anything dirty OUTSIDE website/ is not.
    DIRTY_PATHS=$(print -r -- "$DIRTY" | sed 's/^...//' | awk -F' -> ' '{print $NF}')
    NON_WEBSITE=$(print -r -- "$DIRTY_PATHS" | grep -v '^website/' || true)
    if [[ -z "$NON_WEBSITE" ]]; then
        pass "working tree dirty only under website/ (release prep — expected)"
    elif (( ALLOW_DIRTY )); then
        warn "working tree dirty (--allow-dirty given)"
    else
        fail "working tree is not clean outside website/ — commit or stash first"
    fi
fi

if git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null; then
    LOCAL_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
    REMOTE_HEAD=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")
    if [[ -n "$REMOTE_HEAD" ]]; then
        AHEAD=$(git -C "$REPO_ROOT" rev-list --count origin/main..HEAD)
        BEHIND=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main)
        if [[ "$AHEAD" == "0" && "$BEHIND" == "0" ]]; then
            pass "HEAD == origin/main"
        elif [[ "$BEHIND" != "0" ]]; then
            fail "local main is behind origin/main by $BEHIND — pull first"
        else
            warn "local main is ahead of origin/main by $AHEAD — push after release"
        fi
    fi
fi

# --- Summary -----------------------------------------------------------------

section "Summary"
print "  $FAILS failure(s), $WARNS warning(s)"

if (( FAILS > 0 )); then
    exit 1
fi
exit 0
