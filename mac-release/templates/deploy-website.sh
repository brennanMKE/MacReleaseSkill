#!/usr/bin/env zsh
# Push the website/ tree (landing page + appcast.xml + DMG downloads) to the
# host that serves your update feed, via rsync over SSH.
#
# This is a TEMPLATE for the self-hosted (rsync to a VPS/EC2) path. If you host
# the appcast on GitHub Pages or S3 instead, replace the rsync call with your
# publish step — the env-var preflight above it is still useful.
#
# Reads (override the names in CONFIG to match your shell init):
#   DEPLOY_HOST   user@host (e.g. deploy@updates.example.com) or an SSH alias.
#   DEPLOY_PATH   absolute remote path, e.g. /var/www/myapp.
#   DEPLOY_PORT   (optional) SSH port; defaults to ~/.ssh/config, then 22.
#   DEPLOY_KEY    (optional) path to a private key. Permissions must be 400/600.
#                 Leave unset to let SSH pick from ~/.ssh/config.
#
# Idempotent. rsync --delete keeps the remote in sync with website/, so files
# removed locally also disappear from the live site.
#
# Run AFTER release.sh produced a DMG, AFTER you copied that DMG into
# website/downloads/, and AFTER appcast.xml has the new <item>. Does NOT bump
# versions, sign, notarize, or tag — those are separate scripts.

set -euo pipefail

# ---- CONFIG — edit for your app -------------------------------------------
SITE_DIR_REL="website"
HOST_VAR="DEPLOY_HOST"
PATH_VAR="DEPLOY_PATH"
PORT_VAR="DEPLOY_PORT"
KEY_VAR="DEPLOY_KEY"
PUBLIC_URL="https://updates.example.com/"   # printed at the end for a manual check
# --------------------------------------------------------------------------

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SITE_DIR="$REPO_ROOT/$SITE_DIR_REL"

DEPLOY_HOST="${(P)HOST_VAR:-}"
DEPLOY_PATH="${(P)PATH_VAR:-}"
DEPLOY_PORT="${(P)PORT_VAR:-}"
DEPLOY_KEY="${(P)KEY_VAR:-}"

# --- Preflight ---------------------------------------------------------------

if [[ -z "$DEPLOY_HOST" ]]; then
    print -u2 "error: env var $HOST_VAR is not set"; exit 1
fi
if [[ -z "$DEPLOY_PATH" ]]; then
    print -u2 "error: env var $PATH_VAR is not set"; exit 1
fi

if [[ -n "$DEPLOY_KEY" ]]; then
    if [[ ! -f "$DEPLOY_KEY" ]]; then
        print -u2 "error: key file not found at $DEPLOY_KEY"; exit 1
    fi
    KEY_PERMS=$(stat -f '%Lp' "$DEPLOY_KEY" 2>/dev/null || stat -c '%a' "$DEPLOY_KEY")
    if [[ "$KEY_PERMS" != "400" && "$KEY_PERMS" != "600" ]]; then
        print -u2 "error: $DEPLOY_KEY has permissions $KEY_PERMS — SSH will refuse it."
        print -u2 "       chmod 600 \"$DEPLOY_KEY\""
        exit 1
    fi
fi

if [[ ! -d "$SITE_DIR" ]]; then
    print -u2 "error: $SITE_DIR does not exist; nothing to deploy"; exit 1
fi
if [[ ! -f "$SITE_DIR/index.html" ]]; then
    print -u2 "error: $SITE_DIR/index.html missing — bail before pushing a broken site"; exit 1
fi
if [[ ! -f "$SITE_DIR/appcast.xml" ]]; then
    print -u2 "warning: $SITE_DIR/appcast.xml is missing — Sparkle clients will 404 on update checks"
fi

# --- Deploy ------------------------------------------------------------------

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
[[ -n "$DEPLOY_KEY" ]] && SSH_OPTS+=(-i "$DEPLOY_KEY")
[[ -n "$DEPLOY_PORT" ]] && SSH_OPTS+=(-p "$DEPLOY_PORT")

print "==> Deploying $SITE_DIR_REL/ to $DEPLOY_HOST:$DEPLOY_PATH"
print "    Key:    ${DEPLOY_KEY:-(ssh default)}"
print "    Port:   ${DEPLOY_PORT:-(ssh default)}"

# rsync creates files but not the leaf directory — confirm it exists first so a
# mistyped path fails loudly instead of silently doing nothing useful.
if ! ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "test -d \"$DEPLOY_PATH\""; then
    print -u2 "error: remote directory $DEPLOY_PATH does not exist on $DEPLOY_HOST"
    print -u2 "       ssh in and create it, then re-run"
    exit 1
fi

rsync \
    -avz \
    --delete \
    --exclude '.DS_Store' \
    --exclude '*.swp' \
    --exclude '*.bak' \
    -e "ssh ${SSH_OPTS[*]}" \
    "$SITE_DIR/" \
    "$DEPLOY_HOST:$DEPLOY_PATH/"

print "==> Done. Verify $PUBLIC_URL in a browser."
