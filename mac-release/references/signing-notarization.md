# Code signing & notarization

What Gatekeeper needs to accept a Mac app downloaded from outside the App Store,
and how the release pipeline satisfies it.

## The three requirements

A DMG (and the app inside it) launches without a warning only when all three hold:

1. **Signed with a Developer ID Application certificate** — not a Mac App Store
   or development cert. Issued by your Apple Developer account; lives in the
   login keychain.
2. **Hardened Runtime enabled** (`ENABLE_HARDENED_RUNTIME = YES`). Notarization
   rejects binaries without it.
3. **Notarized and stapled** — submitted to Apple's notary service, which scans
   for malware and returns a ticket; `stapler` attaches the ticket to the DMG so
   it validates offline.

`release.sh` does signing + notarization + stapling; `verify-dmg.sh` proves all
three after the fact (including a quarantine simulation — the only check that
catches broken stapling, since your own machine trusts the cert regardless).

## The Developer ID Application certificate

Add it via **Xcode > Settings > Accounts > Manage Certificates > + > Developer
ID Application**, or download from the Developer portal. Confirm it's present:

```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
```

The identity string the scripts use is
`Developer ID Application: Your Name (TEAMID)`. The Team ID (10 chars) lives in
`Build.xcconfig` as `DEVELOPMENT_TEAM`, and automatic signing
(`CODE_SIGN_STYLE = Automatic`) lets Xcode pick the matching cert at export.

## The notary keychain profile

`notarytool` authenticates to Apple. Store the credentials **once per machine**
under a named profile (`setup-notary.sh` wraps this):

```bash
xcrun notarytool store-credentials "MyApp-notary" \
    --key   ~/.appstoreconnect/AuthKey_ABCDE12345.p8 \
    --key-id ABCDE12345 \
    --issuer 00000000-0000-0000-0000-000000000000
```

Prefer an **App Store Connect API key** (Users and Access > Integrations) over
an Apple-ID + app-specific-password: it doesn't break on password changes and
scopes to notarization. The `.p8` downloads exactly once — store it under
`~/.appstoreconnect/` and back it up.

Verify the profile resolves:

```bash
xcrun notarytool history --keychain-profile "MyApp-notary"
```

The profile **name** is what `release.sh` (`NOTARY_PROFILE`) and the preflight
reference. Each app can use its own profile name, or share one across apps under
the same team.

## Reading notarization failures

`notarytool submit --wait` prints a status. If it's `Invalid`, pull the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "MyApp-notary"
```

Most common causes:

- **Hardened runtime missing** on a binary — set `ENABLE_HARDENED_RUNTIME = YES`.
- **Embedded `.dylib`/framework/helper not signed** — everything inside the
  bundle must carry a valid signature. `--deep` at sign time, or sign nested
  code explicitly.
- **Secure timestamp missing** — sign with `--timestamp` (the scripts do).
- **Mismatched / disallowed bundle identifier**.

See `troubleshooting.md` for the Gatekeeper-side symptoms and fixes.

## Why the quarantine simulation matters

`spctl --assess` on a freshly built DMG passes on your own machine even when the
staple is broken, because your machine already trusts the signing cert and has
seen the notarization online. The recipient's machine, hitting the DMG with a
`com.apple.quarantine` xattr and possibly no network, does not. `verify-dmg.sh`
re-stamps that xattr on a copy and re-runs `spctl` to reproduce exactly what the
recipient sees — always trust that check over a bare local assess.
