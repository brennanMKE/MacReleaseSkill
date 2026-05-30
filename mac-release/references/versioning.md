# Versioning & build numbers

Two numbers, two different jobs. Getting them mixed up is the single most common
way to ship an "update" that Sparkle refuses to offer.

## The two numbers

| Setting | Info.plist key | Role | Who sets it |
|---|---|---|---|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | Human-facing version, SemVer `X.Y.Z` | **You**, per release |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | Monotonic integer Sparkle compares | **`release.sh`**, automatically |

Sparkle decides "is there an update?" by comparing the appcast item's
`sparkle:version` against the installed `CFBundleVersion` — **not** the marketing
string. So the build number must strictly increase every release.

## The build-number scheme: YYYYMMDD

`release.sh` sets `CURRENT_PROJECT_VERSION` at archive time to today's UTC date:

```bash
BUILD_NUMBER="$(date -u +%Y%m%d)"   # e.g. 20260514
xcodebuild archive … CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
```

Why date-based:

- **Always increases** without a counter to maintain or a file to commit.
- **Self-documenting** — you can read the build date off any installed copy.
- **Deterministic** — derived, never hand-edited, so it can't drift.

The static `CURRENT_PROJECT_VERSION = 1` left in `App.xcconfig` is only used by
local Debug builds, which Sparkle never sees. Don't bump it by hand.

The number is **printed at the end of `release.sh`** — paste it into the appcast
`<item>` as `sparkle:version`.

### The same-day collision trap

Two releases on the same UTC day produce the **same** `YYYYMMDD`, so Sparkle
sees "no newer build" and silently offers nothing. The preflight warns when
today's date already appears in the appcast. If you must re-cut the same day,
override for that one run with a finer stamp:

```bash
date -u +%Y%m%d%H%M   # e.g. 202605141930
```

(Stay consistent: once you go to the longer form, future builds must also be ≥
that integer.)

## One source of truth: the xcconfig

`MARKETING_VERSION` lives **only** in `App.xcconfig`. It must NOT appear in
`project.pbxproj`:

- A per-target `MARKETING_VERSION` in pbxproj **silently wins** over the
  xcconfig at build time. You bump the xcconfig, the build ignores it, and you
  ship the old version without noticing.
- The preflight makes this a hard `[✗]`: any `MARKETING_VERSION = …` or
  `CURRENT_PROJECT_VERSION = …` line in pbxproj fails the gate.

To remove an existing override: in Xcode, select the target → Build Settings →
search `MARKETING_VERSION` → if it's bold (set at target level), delete it so it
falls through to the xcconfig. Confirm with:

```bash
grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' MyApp.xcodeproj/project.pbxproj
# (should print nothing)
```

## Info.plist wiring

The Info.plist references the build settings so the values flow from one place:

```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```

This requires an explicit `Info.plist` file (`INFOPLIST_FILE`), not a synthesized
one — the same requirement Sparkle's keys have (`sparkle.md`).

## Per release

1. Bump `MARKETING_VERSION` in `App.xcconfig` (SemVer). Commit alone:
   `Bump version to X.Y.Z`.
2. Leave `CURRENT_PROJECT_VERSION` alone — `release.sh` stamps it.
3. After `release.sh`, copy the printed build number into the appcast item's
   `sparkle:version`; use the marketing version for `sparkle:shortVersionString`.
4. `tag-release.sh` reads `MARKETING_VERSION` and tags `vX.Y.Z`, so the tag
   always matches what shipped.
