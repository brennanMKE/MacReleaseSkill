# MacReleaseSkill

An AI coding skill for **shipping a macOS app outside the App Store**: Developer
ID code signing, Apple notarization + stapling, a drag-to-Applications DMG that
passes Gatekeeper on a clean Mac, and Sparkle auto-updates via a hosted appcast.

The skill itself lives in [`mac-release/`](mac-release/) — a `SKILL.md` plus
reference docs and editable script templates distilled from a real shipping Mac
app's release pipeline.

## What's inside

```
mac-release/
  SKILL.md                  the orchestration guide (when to use, pipeline, refs)
  references/               load-on-demand background
    signing-notarization.md   Developer ID, hardened runtime, notarytool
    sparkle.md                EdDSA keys, Info.plist wiring, generate_keys
    versioning.md             MARKETING_VERSION vs build number, drift traps
    appcast.md                appcast <item> format, sign_update
    website-deploy.md         hosting the appcast + DMG
    troubleshooting.md        Gatekeeper / notarization / Sparkle failures
  templates/                copy into your app, edit the CONFIG block
    preflight.sh  release.sh  verify-dmg.sh  tag-release.sh
    appcast-item.sh  setup-notary.sh  deploy-website.sh
    App.xcconfig  Build.xcconfig  appcast.xml  RELEASE.md
```

## The release pipeline

`preflight` → bump version → `release` (sign/notarize/staple/DMG) → `verify-dmg`
→ smoke-test → update appcast → `deploy` + `tag`. See
[`mac-release/templates/RELEASE.md`](mac-release/templates/RELEASE.md) for the
full checklist.

The templates carry comments that encode real failures (why the DMG name must
equal the volume name, the same-day build-number collision, the
`GENERATE_INFOPLIST_FILE` Sparkle-key gotcha). Keep those comments when adapting.

## Install

```bash
./install.sh                 # link into Claude Code / Codex skills dirs
./install.sh --project DIR   # also link into DIR/.cursor/skills
```

`install.sh` symlinks the `mac-release/` skill folder into each detected tool's
skills directory, so edits are live.

## License

MIT — see [LICENSE](LICENSE).
