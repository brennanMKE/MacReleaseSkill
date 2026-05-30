# Cutting a <APP> release

End-to-end checklist for producing a signed, notarized, stapled DMG that
Gatekeeper accepts on a clean Mac, and advertising it through Sparkle. Pairs
with the scripts in this directory.

> Copy this file into your app's `scripts/` (or repo root), then replace
> `<APP>` and the example URLs/paths with your app's values.

## One-time setup

- **Apple Developer account** with a **Developer ID Application** certificate
  installed in your login keychain. Put the Team ID in
  `Configuration/Build.xcconfig` (`DEVELOPMENT_TEAM`).
- **Notary keychain profile.** Run `scripts/setup-notary.sh` once per machine.
  It stores an App Store Connect API key under a named profile that
  `notarytool` looks up. See `references/notarization.md`.
- **Sparkle EdDSA key pair.** `generate_keys` stores the private key in your
  keychain and prints the public key; paste the public key into
  `Configuration/App.xcconfig` as `SU_PUBLIC_ED_KEY`. Back up the private key.
  See `references/sparkle.md`.
- **Hosting** for `appcast.xml` and the DMG downloads (self-hosted, GitHub
  Pages, or S3). Put the feed URL in `App.xcconfig` as `SU_FEED_URL`.
- **(Self-hosted only) deploy env vars** in your shell init:
  `DEPLOY_HOST`, `DEPLOY_PATH`, optionally `DEPLOY_KEY` / `DEPLOY_PORT`.

## Release steps

0. **Run the preflight**

   ```bash
   scripts/preflight.sh
   ```

   Walks every readiness gate (build, tests, version drift, Sparkle keys,
   signing cert, notary profile, deploy env vars, working tree). Fix every
   `[✗]` before continuing; `[!]` warnings are advisory. `--skip-build` for a
   faster ad-hoc check, `--strict` to promote warnings to failures.

1. **Choose the version**

   Bump `MARKETING_VERSION` in `Configuration/App.xcconfig` — the single source
   of truth. Do **not** touch `CURRENT_PROJECT_VERSION`: `release.sh` overrides
   it at archive time with today's UTC date (`YYYYMMDD`), the monotonic build
   number Sparkle compares. Commit the bump on its own: `Bump version to X.Y.Z`.

2. **Sanity-check the build and run tests**

   Build clean and run your test suite. Don't proceed over a red test.

3. **Run the release pipeline**

   ```bash
   scripts/release.sh
   ```

   Archives → exports → signs → notarizes → staples → DMG-packages → verifies.
   Output: `dist/<APP>-<sha>.dmg`. Notarization round-trip is typically 2–10
   minutes; the script blocks via `notarytool ... --wait`.

   **Do not run this autonomously from an agent session** — the submission
   modifies a shared external system (Apple's notary service).

4. **Verify the DMG**

   ```bash
   scripts/verify-dmg.sh dist/<APP>-<sha>.dmg
   ```

   Confirms signing, notarization, stapling, and Gatekeeper acceptance under a
   simulated download-quarantine. All checks should pass.

5. **Smoke-test on a clean Mac**

   A fresh user account that has never run the app, or a spare Mac/VM where the
   bundle ID hasn't been seen. Drag from the DMG to `/Applications`,
   double-click, confirm it opens with no right-click bypass and no
   "unidentified developer" warning.

6. **Update the appcast and changelog**

   - Copy the DMG to `website/downloads/<APP>-X.Y.Z.dmg`.
   - Sign it: run Sparkle's `sign_update` over the DMG (see
     `references/appcast.md`) to get `sparkle:edSignature` and `length`.
   - Prepend an `<item>` to `website/appcast.xml`: use the **YYYYMMDD build
     number printed by `release.sh`** for `sparkle:version`, the marketing
     version for `sparkle:shortVersionString`, plus the signature, length, and
     enclosure URL.
   - Stamp your changelog with the user-visible changes.

7. **Publish the appcast** (self-hosted)

   ```bash
   scripts/deploy-website.sh
   ```

   rsyncs `website/` to your host. Sparkle clients poll the feed and surface
   the update within their check interval.

8. **Tag the release**

   ```bash
   scripts/tag-release.sh
   ```

   Reads `MARKETING_VERSION`, creates an annotated `vX.Y.Z` tag on HEAD, and
   prompts before pushing.

9. **Write release notes** — user-visible changes only; mirror them in the
   changelog so the public site and the git tag stay in sync.

## Troubleshooting

See `references/troubleshooting.md` for the common Gatekeeper / notarization /
DMG-rename failures and their fixes.
