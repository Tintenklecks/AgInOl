# AgInOl Update Distribution

AgInOl uses Sparkle for in-app macOS updates. Sparkle owns the secure updater flow:
check feed, download archive, verify signature, quit the running app, replace the
`.app` bundle, and relaunch.

## Xcode Setup

Add Sparkle to the macOS `AgInOl` target from Xcode:

1. File > Add Package Dependencies...
2. Package URL: `https://github.com/sparkle-project/Sparkle`
3. Product: `Sparkle`
4. Target: `AgInOl`

Then add these generated Info.plist keys to the `AgInOl` target build settings:

```text
SUFeedURL = https://aiia.li/downloads/aginol_appcast.xml
SUPublicEDKey = <Sparkle EdDSA public key>
```

The Swift code is guarded with `canImport(Sparkle)`, so the project still builds
before the package is added. Until Sparkle is linked, the update button shows a
configuration alert instead of checking for updates.

## Release Files

Publish these files in the same download area:

```text
appcast.xml
aginol.json
AgInOl-<version>.zip
```

`appcast.xml` is the authoritative Sparkle update feed. `aginol.json` is optional
metadata for a website or download page.

Before publishing a release:

1. Archive, sign, and notarize `AgInOl.app`.
2. Zip the notarized app.
3. Sign the zip with Sparkle's signing tool.
4. Replace the placeholders in `appcast.xml` and `aginol.json`.
5. Upload the zip and metadata files.
