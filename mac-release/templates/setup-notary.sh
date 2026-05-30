#!/usr/bin/env zsh
# Store App Store Connect API credentials under a notarytool keychain profile.
# Run this ONCE per machine. release.sh and the preflight look for the profile
# by name ($NOTARY_PROFILE).
#
# This is a TEMPLATE. Fill in the CONFIG block from your App Store Connect API
# key (Users and Access > Integrations > App Store Connect API). Each key has:
#   - a Key ID (10 chars, e.g. ABCDE12345)
#   - an Issuer ID (a UUID)
#   - a one-time .p8 download (store it under ~/.appstoreconnect/)
#
# Prefer an API key over an Apple-ID + app-specific-password: it doesn't expire
# on password changes and scopes cleanly to notarization.

set -euo pipefail

# ---- CONFIG — edit for your app -------------------------------------------
NOTARY_PROFILE="MyApp-notary"
KEY_ID="ABCDE12345"
ISSUER_ID="00000000-0000-0000-0000-000000000000"
KEY_PATH="$HOME/.appstoreconnect/AuthKey_${KEY_ID}.p8"
# --------------------------------------------------------------------------

if [[ ! -f "$KEY_PATH" ]]; then
    print -u2 "error: API key not found at $KEY_PATH"
    print -u2 "       Download the .p8 from App Store Connect and place it there."
    exit 1
fi

print "==> Storing credentials under keychain profile '$NOTARY_PROFILE'"
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --key "$KEY_PATH" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID"

print "==> Verifying"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    && print "    OK — '$NOTARY_PROFILE' is configured."
