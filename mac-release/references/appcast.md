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

## Signing the DMG

Compute the signature with Sparkle's `sign_update`, using the **same
`--account`** you generated the key with (`sparkle.md`):

```bash
<...>/artifacts/sparkle/Sparkle/bin/sign_update \
    --account MyApp \
    dist/MyApp-1.0.1.dmg
```

It prints both attributes ready to paste:

```
sparkle:edSignature="…" length="12345678"
```

> Without `--account MyApp`, `sign_update` looks under the default account
> `ed25519` and fails with **"Signing key not found for account ed25519."** This
> is the single most common appcast-signing error.

## Validate before publishing

```bash
xmllint --noout website/appcast.xml   # well-formed XML (the preflight checks this too)
```

Then publish (`website-deploy.md`). Sparkle clients pick up the new item on
their next poll, or immediately via "Check for Updates…".

## Sanity checklist per release

- [ ] DMG copied to the hosting path the `enclosure url` points at.
- [ ] `sparkle:version` = the YYYYMMDD printed by `release.sh` (and higher than
      the previous item).
- [ ] `sparkle:shortVersionString` = `MARKETING_VERSION`.
- [ ] `sparkle:edSignature` + `length` = fresh `sign_update` output for *this*
      DMG (re-sign if you rebuilt).
- [ ] Item prepended, XML still valid.
