# Release troubleshooting

Symptoms and fixes for the failures that actually recur when shipping a signed,
notarized, Sparkle-updated Mac app.

## Gatekeeper / notarization

**`spctl --assess` passes on my Mac but the recipient sees a warning.**
Your machine trusts the cert and has seen the notarization online, so a bare
local assess is not representative. Always trust `verify-dmg.sh`'s **quarantine
simulation**, which re-stamps `com.apple.quarantine` on a copy and re-assesses —
that's the recipient's actual experience. A failure there means the staple is
missing or notarization didn't really succeed.

**`spctl` fails on the freshly-signed `.app` but the DMG is fine.**
Stapling-order artifact: the pipeline staples the **DMG**, not the inner `.app`.
Re-test via `verify-dmg.sh <dmg>` rather than assessing the raw `.app`.

**Notarization came back `Invalid`.**
Pull the actual reasons:

```bash
xcrun notarytool log <submission-id> --keychain-profile "MyApp-notary"
```

Usual causes: Hardened Runtime missing (`ENABLE_HARDENED_RUNTIME = YES`); an
embedded `.dylib`/framework/helper without a valid signature; missing secure
timestamp (sign with `--timestamp`); disallowed bundle ID. See
`signing-notarization.md`.

**DMG fails Gatekeeper on the test Mac even though it's notarized.**
The test Mac may hold a previous **unstapled** copy in its quarantine cache.
Clear it and retest:

```bash
spctl --reset-default --type execute   # sometimes a logout helps too
```

**`notarytool` can't find the profile.**
`xcrun notarytool history --keychain-profile "MyApp-notary"` must succeed. If
not, re-run `setup-notary.sh`. Profiles are per-machine and per-login-keychain —
a new Mac needs its own.

## The DMG renamed itself mid-pipeline

If a step fails because the DMG "disappeared," macOS likely renamed it on disk to
match the volume name during the notarytool roundtrip — this happens when the
**filename differs from `--volname`**. `release.sh` avoids it by building,
signing, notarizing, and stapling against a fixed name (`MyApp.dmg` ==
`--volname MyApp`) and only renaming to `MyApp-<sha>.dmg` **after** stapling.
Keep that ordering if you modify the script.

## Sparkle: update not offered

**"You're up to date" but it names a newer version than the one it says you're
running** (e.g. "1.0.3 is newest, you are running 1.0.2").
The self-contradiction means two fields drifted from the artifact. Sparkle
decides on `CFBundleVersion` but prints the marketing strings, so this appears
when the shipped DMG (a) was archived without bumping `MARKETING_VERSION` (its
`CFBundleShortVersionString` is the *old* version) and (b) carries a
`CFBundleVersion` ≥ the feed's newest `sparkle:version` (often a hand-typed
`sparkle:version` one off from the real build). Confirm by reading the shipped
DMG directly:

```bash
hdiutil attach MyApp-X.Y.Z.dmg -nobrowse -readonly -mountrandom /tmp
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Volumes/.../MyApp.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion'            /Volumes/.../MyApp.app/Contents/Info.plist
```

Fix the *process*, not just the feed: bump `MARKETING_VERSION` before archiving
(the `release.sh` consistency gate now hard-fails otherwise), and author the item
with `appcast-item.sh` so `sparkle:version` is read from the DMG instead of
typed. A build already in users' hands can only be superseded by a later build
whose number exceeds it. Full write-up in `versioning.md`.

**"Check for Updates…" says you're up to date, but there's a new version.**
Sparkle compares `sparkle:version` (an integer = `CFBundleVersion`), not the
marketing string. Check, in order:

1. The appcast item's `sparkle:version` is **higher** than the installed
   `CFBundleVersion`. Same-day re-release? Two `YYYYMMDD` builds collide — see
   `versioning.md`.
2. `MARKETING_VERSION`/build number actually changed in the *shipped* bundle —
   a pbxproj override may be shadowing the xcconfig (`versioning.md`).
3. The appcast is actually live at `SUFeedURL` (open it in a browser).

**Update downloads but fails to install / "signature does not match."**
The DMG's `sparkle:edSignature` doesn't verify against the app's
`SUPublicEDKey`. Re-run `sign_update --account MyApp` over the *exact* DMG you
published (re-sign if you rebuilt it), and confirm the `--account` matches the
one used for `generate_keys`.

**`sign_update` → "Signing key not found for account ed25519."**
You omitted `--account MyApp`; it fell back to the default account. Add the flag
(`appcast.md`).

**The "Check for Updates…" menu item is greyed out.**
Expected when `SUFeedURL` is empty. Confirm the built bundle's Info.plist
actually carries the key — a synthesized Info.plist (`GENERATE_INFOPLIST_FILE =
YES`) commonly drops it (`sparkle.md`):

```bash
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "/Applications/MyApp.app/Contents/Info.plist"
```

## Build settings shadowing

**I bumped the version but shipped the old one.**
A per-target `MARKETING_VERSION` (or `CURRENT_PROJECT_VERSION`) in
`project.pbxproj` silently overrides `App.xcconfig`. Remove it (the preflight
fails on its presence). See `versioning.md`.

## Tooling missing

- `create-dmg not installed` → `brew install create-dmg`
- `fileicon not installed` → `brew install fileicon`
- `xmllint`/`stapler`/`spctl`/`notarytool` ship with macOS + Xcode command-line
  tools; if missing, `xcode-select --install` or point `DEVELOPER_DIR` at a full
  Xcode.
