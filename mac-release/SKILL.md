---
name: mac-release
description: Ship a macOS app outside the App Store — code sign with Developer ID, notarize and staple, package a drag-to-Applications DMG that passes Gatekeeper on a clean Mac, and publish Sparkle auto-updates via an appcast. Trigger when the user wants to release/distribute a Mac app, set up signing or notarization, fix Gatekeeper "unidentified developer" / quarantine warnings, build or verify a DMG, configure Sparkle/appcast/EdDSA update signing, sort out MARKETING_VERSION vs build-number drift, or stand up a release pipeline (preflight → release → verify → appcast → tag) for a new Mac app. Provides editable script templates and reference docs distilled from a shipping app.
license: MIT
metadata:
  author: Brennan Stehling
  version: "1.0"
---

Help ship a macOS app for **direct distribution** (outside the Mac App Store):
Developer ID signing, Apple notarization + stapling, a DMG that launches clean
on a fresh Mac, and Sparkle auto-updates driven by a hosted appcast.

This skill packages a battle-tested pipeline as **editable templates** plus
**reference docs**. The templates carry hard-won comments (why DMG name must
equal volname, why the build dir is torn down, the same-day build-number trap) —
preserve those comments when adapting; they encode real failures.

## When to use

- Standing up a release pipeline for a new Mac app, or copying one app's release
  flow to another.
- Code signing, notarization, stapling, or DMG packaging questions/failures.
- Gatekeeper warnings ("unidentified developer", quarantine rejection on a clean
  Mac).
- Sparkle setup: EdDSA keys, Info.plist keys, appcast items, update signing.
- Version/build-number drift (`MARKETING_VERSION` vs `CURRENT_PROJECT_VERSION`,
  Sparkle "no update available").

## The pipeline

Seven steps, each backed by a template script. Full checklist:
`templates/RELEASE.md`.

1. **Preflight** (`preflight.sh`) — read-only gates: build/tests, version drift,
   Sparkle keys, signing cert, notary profile, deploy config, clean tree.
2. **Bump version** — `MARKETING_VERSION` in `App.xcconfig` only. The build
   number is set automatically at archive time (see `versioning.md`).
3. **Release** (`release.sh`) — archive → export → sign → notarize → staple →
   DMG → verify. Output: `dist/<App>-<sha>.dmg`.
4. **Verify** (`verify-dmg.sh`) — proves signing/notarization/stapling and
   simulates the recipient's download-quarantine.
5. **Smoke-test** on a clean Mac / fresh user account.
6. **Appcast** — copy the DMG to hosting, `sign_update` it, prepend an `<item>`,
   stamp the changelog.
7. **Publish + tag** (`deploy-website.sh`, `tag-release.sh`).

> **Safety — do not notarize or publish autonomously from an agent session.**
> `release.sh` submits to Apple's notary service and `deploy-website.sh` /
> `tag-release.sh` push to shared/external systems. These modify outside state:
> prepare everything, then hand the actual submit/publish/tag to the user (or
> get explicit per-run approval). Preflight, verify, and editing the appcast are
> safe to run.

## Adapting the templates to an app

The scripts are not drop-in — they're parameterized. For each one:

1. Copy it into the app's `scripts/` directory.
2. Edit the **`CONFIG` block** at the top (app name, scheme, Team ID, signing
   identity, notary profile name, project/workspace path, xcconfig/appcast
   paths).
3. Delete gates/steps that don't apply and add app-specific ones. The preflight
   especially is meant to grow project-specific gates over time (a sentinel
   resource that must be bundled, a pinned dependency, etc.).
4. `chmod +x` the shell scripts.

Config files (`App.xcconfig`, `Build.xcconfig`, `appcast.xml`) are starting
points — merge their keys into the app's existing configuration rather than
overwriting.

## References — load what the task needs

| Task / symptom | Reference |
|---|---|
| Developer ID cert, hardened runtime, notary profile, reading notary logs, why the quarantine sim matters | `references/signing-notarization.md` |
| Sparkle wiring: EdDSA `generate_keys`, per-app `--account`, Info.plist keys, `GENERATE_INFOPLIST_FILE` gotcha | `references/sparkle.md` |
| `MARKETING_VERSION` vs `CURRENT_PROJECT_VERSION`, YYYYMMDD build number, pbxproj override drift, "no update available" | `references/versioning.md` |
| Appcast `<item>` format, `sign_update`, `edSignature`/`length`, "Signing key not found for account ed25519" | `references/appcast.md` |
| Hosting the appcast + DMG (self-host/Pages/S3/Releases), `deploy-website.sh` | `references/website-deploy.md` |
| Gatekeeper warnings, notarization `Invalid`, DMG self-rename, Sparkle update-not-offered, greyed-out menu item | `references/troubleshooting.md` |

## Templates

| File | Purpose |
|---|---|
| `templates/preflight.sh` | Read-only release-readiness gates (`--strict`, `--skip-build`, `--allow-dirty`) |
| `templates/release.sh` | Archive → sign → notarize → staple → DMG → verify |
| `templates/verify-dmg.sh` | Validate a DMG incl. quarantine simulation |
| `templates/tag-release.sh` | Annotated `vX.Y.Z` tag from `MARKETING_VERSION` |
| `templates/setup-notary.sh` | One-time notarytool keychain profile (API key) |
| `templates/deploy-website.sh` | rsync `website/` (appcast + DMG) to a host |
| `templates/App.xcconfig` | Version + bundle id + Sparkle keys (source of truth) |
| `templates/Build.xcconfig` | Toolchain, platform, signing/team, hardened runtime |
| `templates/appcast.xml` | Sparkle feed skeleton with one annotated `<item>` |
| `templates/RELEASE.md` | The per-app end-to-end release checklist |

## Prerequisites

- Apple Developer account; **Developer ID Application** cert in the login
  keychain; an App Store Connect API key for notarization.
- `brew install create-dmg fileicon`; Xcode command-line tools for
  `notarytool`/`stapler`/`spctl`/`xmllint`.
- Sparkle added as a dependency (SPM) so `generate_keys`/`sign_update` are
  available.
