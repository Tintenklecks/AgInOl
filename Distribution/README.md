# AgInOl Update Distribution

AgInOl uses Sparkle for in-app macOS updates. Sparkle owns the secure updater flow:
check feed, download archive, verify signature, quit the running app, replace the
`.app` bundle, and relaunch.

`RELEASE_AUTOMATION.md` describes how the manifests are produced — read that
before touching `appcast.xml` or `aginol.json`, which are **generated files**.

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

Generate the key pair once with Sparkle's `generate_keys`; it stores the private
key in the login Keychain and prints the public key for `SUPublicEDKey`.

## Cutting a release

1. Bump the build number (`agvtool next-version -all`, or `CURRENT_PROJECT_VERSION`
   in Xcode) and the marketing version if it changed.
2. Write `release-notes/<marketing version>.html` (copy `TEMPLATE.html`).
3. Run:

   ```bash
   Distribution/scripts/build_release.sh
   ```

   This archives, exports with Developer ID, notarizes, staples, zips into
   `releases/`, and regenerates `appcast.xml` + `aginol.json`.
4. Upload the new zip plus both manifests to the download area.
5. Commit the regenerated manifests.

`SKIP_NOTARIZE=1` gives a local dry run that skips only the notarization step.

To re-generate the manifests without rebuilding — after re-downloading older
archives, or to fix a URL prefix — run `Distribution/scripts/update_manifest.sh`
on its own.

## Release Files

Published in the same download area:

```text
appcast.xml                    # authoritative Sparkle feed, generated
aginol.json                    # website metadata, generated from the feed
AgInOl-<version>-<build>.zip   # notarized, stapled, signed archive
```

Never overwrite a published zip: clients verify a signature over the exact
bytes, so a changed file breaks updates for anyone holding the old manifest.
