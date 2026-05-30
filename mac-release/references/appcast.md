# The appcast & per-release signing

`appcast.xml` is the RSS feed Sparkle polls. Each release adds one `<item>`. This
file covers the item format and how to compute the EdDSA signature. The one-time
key/Info.plist wiring is in `sparkle.md`; the build-number rules are in
`versioning.md`.

## Item anatomy

```xml
<item>
  <title>1.0.1</title>
  <pubDate>Mon, 12 May 2026 00:00:00 +0000</pubDate>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[
    <h2>What's new in 1.0.1</h2>
    <ul><li>Fixed …</li></ul>
  ]]></description>
  <enclosure
    url="https://updates.example.com/downloads/MyApp-1.0.1.dmg"
    sparkle:version="20260512"
    sparkle:shortVersionString="1.0.1"
    sparkle:edSignature="EDDSA_SIG_FROM_sign_update"
    length="12345678"
    type="application/octet-stream" />
</item>
```

The fields that must be exactly right:

| Attribute | Value | Source |
|---|---|---|
| `sparkle:version` | the integer Sparkle compares | YYYYMMDD build number printed by `release.sh` |
| `sparkle:shortVersionString` | human version | `MARKETING_VERSION` |
| `sparkle:edSignature` | update signature | `sign_update` output |
| `length` | DMG byte count | `sign_update` output (or `stat -f%z`) |
| `url` | where the DMG is hosted | your `enclosure` URL |

- **Order items newest-first**; prepend each release.
- `minimumSystemVersion` should match your `MACOSX_DEPLOYMENT_TARGET`.
- Release notes: either inline `<description>` HTML (CDATA) or a
  `<sparkle:releaseNotesLink>` pointing at a hosted HTML file.

## Generate the item — don't hand-type it

**The correct way to author an item is `appcast-item.sh <dmg>`**, not typing the
attributes. It derives every value from the artifact: it mounts the DMG, reads
`CFBundleShortVersionString` / `CFBundleVersion` from the bundle inside, computes
the byte `length`, and runs `sign_update` for the signature. Because nothing is
typed, the feed cannot drift from the DMG — the exact drift that ships a broken
"You're up to date" update feed (see `versioning.md`).

```bash
scripts/appcast-item.sh dist/MyApp-1.0.1.dmg
```

It prints a complete `<item>` ready to paste (newest-first) into `appcast.xml`,
then reminds you to copy the DMG to your downloads dir and fill in the release
notes. `release.sh` runs it automatically at the end of every release, so the
block is already in your terminal scrollback.

### What it's doing under the hood

The signature comes from Sparkle's `sign_update`, using the **same `--account`**
you generated the key with (`sparkle.md`):

```bash
<...>/artifacts/sparkle/Sparkle/bin/sign_update --account MyApp dist/MyApp-1.0.1.dmg
# -> sparkle:edSignature="…" length="12345678"
```

> Without `--account MyApp`, `sign_update` looks under the default account
> `ed25519` and fails with **"Signing key not found for account ed25519."** This
> is the single most common appcast-signing error.

Only fall back to running `sign_update` by hand (and reading the version fields
with `PlistBuddy`) if `appcast-item.sh` can't locate the signing tool — fix
`SIGN_UPDATE_CANDIDATES` in its CONFIG block instead.

## Validate before publishing

```bash
xmllint --noout website/appcast.xml   # well-formed XML (the preflight checks this too)
```

Then publish (`website-deploy.md`). Sparkle clients pick up the new item on
their next poll, or immediately via "Check for Updates…".

## Sanity checklist per release

- [ ] Item generated with `appcast-item.sh <dmg>` (not hand-typed).
- [ ] DMG copied to the hosting path the `enclosure url` points at, named to
      match (`<APP>-<X.Y.Z>.dmg`).
- [ ] Item prepended (newest-first), `<description>` release notes filled in.
- [ ] `xmllint --noout appcast.xml` clean (the preflight checks this too).
- [ ] Preflight's appcast↔DMG consistency gate passes against the local DMG.

If you ever edit attributes by hand, re-verify: `sparkle:version` must equal the
DMG's `CFBundleVersion`, `sparkle:shortVersionString` its
`CFBundleShortVersionString`, and `length` its byte count — `appcast-item.sh`
guarantees all three, which is why it's the default.
