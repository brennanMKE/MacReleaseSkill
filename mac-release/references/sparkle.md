# Sparkle auto-update setup

Wiring [Sparkle](https://sparkle-project.org) into a Mac app so it can update
itself from a hosted appcast. Covers the EdDSA signing keys, the Info.plist
keys, and where the helper binaries live.

## How the pieces fit

- The app embeds **`SUFeedURL`** (where to fetch `appcast.xml`) and
  **`SUPublicEDKey`** (to verify update signatures) in its `Info.plist`.
- Each release's DMG is signed with your **EdDSA private key** via `sign_update`;
  the signature goes into the appcast `<item>` as `sparkle:edSignature`.
- Sparkle clients poll the feed, compare `sparkle:version` (the integer build
  number) against the running `CFBundleVersion`, verify the signature against
  the embedded public key, download, and install on relaunch.

The appcast `<item>` format and per-release signing live in `appcast.md`. This
file covers the one-time wiring.

## One-time setup

### 1. Add the Sparkle dependency

Swift Package Manager (recommended): add
`https://github.com/sparkle-project/Sparkle` to the app target (or to a local
package the app depends on). Sparkle ships as a prebuilt XCFramework, so its
helper tools arrive as **SPM artifacts**, not source.

### 2. Generate the EdDSA key pair

After any `swift build` / `xcodebuild` that resolves Sparkle, the tools land at:

```
<...>/.build/artifacts/sparkle/Sparkle/bin/{generate_keys,sign_update}
```

or, under Xcode-resolved packages:

```
~/Library/Developer/Xcode/DerivedData/<App>-*/SourcePackages/artifacts/sparkle/Sparkle/bin/…
```

(identical binaries). Find the path:

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*sparkle/Sparkle/bin/generate_keys' 2>/dev/null
```

Generate the pair. Use a **per-app `--account` name** so multiple apps don't
collide in the keychain:

```bash
./generate_keys --account MyApp                       # private → keychain, public → stdout
./generate_keys --account MyApp -x myapp-sparkle.key  # also export the private key to a file
./generate_keys --account MyApp -p > myapp-sparkle.pub # save the public key
```

The private key is stored in your login keychain. **Back up the exported
`.key`** somewhere safe — losing it means existing installs can never verify a
future update (you'd have to ship a hardcoded-key transition build). The `.pub`
value is what goes into Info.plist.

On a new Mac, import the backed-up private key:

```bash
./generate_keys --account MyApp -f myapp-sparkle.key
```

> The `--account` name chosen here MUST match the `--account` passed to
> `sign_update` at release time (see `appcast.md`). Mismatch → "Signing key not
> found for account …".

### 3. Embed the keys in Info.plist

The cleanest approach is a real `Info.plist` whose values reference build
settings, with the keys defined in `App.xcconfig`:

```xml
<key>SUFeedURL</key>
<string>$(SU_FEED_URL)</string>
<key>SUPublicEDKey</key>
<string>$(SU_PUBLIC_ED_KEY)</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

```
// App.xcconfig
HTTPS = https:/
SU_FEED_URL = $HTTPS/updates.example.com/appcast.xml
SU_PUBLIC_ED_KEY = <base64 public key from step 2>
```

> **Gotcha with `GENERATE_INFOPLIST_FILE = YES`.** A synthesized Info.plist does
> not honor arbitrary keys, and `INFOPLIST_KEY_*` build settings cover only a
> fixed allow-list (Sparkle's keys aren't on it in most Xcode versions). Use an
> explicit `Info.plist` file with `INFOPLIST_FILE = …/Info.plist` and
> `GENERATE_INFOPLIST_FILE = NO`. Always confirm by inspecting the built
> bundle's `Contents/Info.plist`.

### 4. Add the updater + menu item

Instantiate `SPUStandardUpdaterController` and add a **"Check for Updates…"**
menu item bound to its `checkForUpdates:` action. A common pattern gates the
menu item on a non-empty `SUFeedURL`, so the app degrades gracefully before the
feed exists.

## Verification

- `SUFeedURL` empty → "Check for Updates…" stays disabled.
- `SUFeedURL` set → menu item enables; clicking runs Sparkle's "fetching
  appcast" UI.
- A fresh appcast `<item>` with a higher `sparkle:version` → the user is
  prompted, the DMG downloads, signature verifies, and Sparkle installs on
  relaunch.

Inspect what shipped:

```bash
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL'      "/Applications/MyApp.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey'  "/Applications/MyApp.app/Contents/Info.plist"
```
