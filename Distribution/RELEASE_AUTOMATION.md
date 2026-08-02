# Automating the AgInOl update manifest

The goal: after every release build of the macOS app, the update feed
(`appcast.xml`) and the website metadata (`aginol.json`) describe that build —
with correct version, build number, minimum system version, file size, SHA-256
and Sparkle EdDSA signature — without anyone editing XML by hand.

## Principle

**The built app bundle is the single source of truth.** Every field in the
manifest is *derived*, never typed:

| Manifest field                  | Derived from                                       |
| ------------------------------- | -------------------------------------------------- |
| `sparkle:shortVersionString`    | `CFBundleShortVersionString` in the app's Info.plist |
| `sparkle:version`               | `CFBundleVersion` (the build number)                |
| `sparkle:minimumSystemVersion`  | `LSMinimumSystemVersion`                            |
| `enclosure length`              | `stat` of the signed zip                            |
| `sparkle:edSignature`           | `sign_update` over the zip, EdDSA key from Keychain |
| `sha256` (website only)         | `shasum -a 256` of the zip                          |
| `url`                           | download URL prefix + zip filename                  |
| `pubDate`                       | zip mtime                                           |

Exactly two things stay human-authored:

1. the version bump in Xcode (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`),
2. the release notes for that version.

Everything else is a pure function of the artifact. That is what makes the step
safe to run on every build: re-running it can only reproduce the same answer.

## The archive folder is the state

`Distribution/releases/` holds *every* shipped zip, one file per release:

```text
Distribution/releases/
├── AgInOl-1.0-13.zip
├── AgInOl-1.0-13.html      # release notes for that build
├── AgInOl-1.1-17.zip
└── AgInOl-1.1-17.html
```

The feed is not appended to — it is **regenerated from the folder** on every
build by Sparkle's own `generate_appcast`, which opens each zip, reads the
Info.plist inside, signs the archive, and writes the complete `<item>` list
sorted by build number. Consequences worth having:

- No incremental edit, so no drift and no half-written feed.
- Deleting a zip retracts that version; adding an old zip back restores it.
- Delta updates (`.delta` files) appear automatically once two builds are in
  the folder — Sparkle generates and references them for you.
- The version history the feed shows is auditable: it *is* the folder listing.

`aginol.json` is then a projection of the newest `<item>` in the feed plus the
SHA-256 of its zip, so the website and the updater can never disagree.

### Where that folder lives

The zips are build artifacts and are not committed (`releases/.gitignore`), so
the folder has to be reconstructable — the download area is the canonical copy.
Two workable policies:

- **Mirror before generating.** `rsync` the published zips down into
  `releases/` before the manifest step. The regenerated feed then keeps the
  full history and Sparkle can build delta updates against the previous build.
- **Latest only.** Build on a clean machine, let `releases/` hold just the new
  zip. The feed is valid — clients only ever need the newest item — but it
  loses the older `<item>`s and the deltas, so every update is a full download.

Start with "latest only" if that is what a fresh checkout gives you; move to
mirroring when download size starts to matter. Only the feed is affected, never
the app's ability to update.

## Where it hooks into the build

```text
xcodebuild archive
   └─ export (Developer ID)        ExportOptions.plist
      └─ notarytool submit --wait
         └─ stapler staple
            └─ ditto -c -k --keepParent → Distribution/releases/AgInOl-<v>-<b>.zip
               └─ copy release notes  → Distribution/releases/AgInOl-<v>-<b>.html
                  └─ generate_appcast Distribution/releases → appcast.xml
                     └─ appcast_to_json.py → aginol.json
                        └─ upload (rsync/scp) + git commit of the manifests
```

The two boxes at the bottom — feed regeneration and JSON projection — are the
only ones that touch the manifest, and they are one script:
`Distribution/scripts/update_manifest.sh`. It is idempotent, needs no network,
and can be run on its own against an existing zip if a release ever needs to be
re-published.

Notarization sits *before* zipping on purpose: Sparkle verifies the EdDSA
signature over the zip, so the zip must contain the final, stapled app. Signing
first and notarizing later would invalidate the signature.

### Why not "just append an entry in CI"

An appended entry has to restate facts that already exist in the bundle
(version, min OS), and each restatement is a chance to ship a feed that points
at the wrong build — the failure mode being an update the app either never
offers or refuses to install after download. Deriving from the artifact removes
the class of error rather than testing for it.

## Keys and secrets

- Generate once with Sparkle's `generate_keys`. The private EdDSA key lives in
  the login Keychain; `generate_appcast` and `sign_update` find it there.
- The public key goes into the `AgInOl` target as `SUPublicEDKey`, next to
  `SUFeedURL`. Shipping it in the app is the point — it pins the feed.
- For a CI runner, export the private key (`generate_keys -x key.txt`) and pass
  it as `SPARKLE_PRIVATE_KEY` / `--ed-key-file`, never in the repo.
- Notarization uses a stored `notarytool` keychain profile
  (`xcrun notarytool store-credentials`), referenced by `NOTARY_PROFILE`.

## Hosting

`DOWNLOAD_URL_PREFIX` is the only place that knows where files live. Today that
is `https://aiia.li/downloads/`. Swapping to GitHub Releases means changing
that one variable and pointing the upload step at `gh release upload` — the
manifest generation does not change, because it only needs to know the prefix
under which the zip will be reachable.

Whatever the host: `appcast.xml` must be served over HTTPS, and the zips should
be served with a stable, versioned filename. Never overwrite a published zip —
a changed file invalidates the signature that clients already downloaded a
manifest for.

## Version discipline

`sparkle:version` is what Sparkle compares, and it must increase monotonically
across *all* releases, including builds that keep the same marketing version.
Bumping `CURRENT_PROJECT_VERSION` on every release build (manually, or with
`agvtool next-version -all` in the release lane) is enough. The build script
refuses to overwrite an existing zip, so a forgotten bump fails loudly at build
time instead of silently shipping a feed the app ignores.

## Scripts in this folder

| Script                        | Does                                                        |
| ----------------------------- | ----------------------------------------------------------- |
| `scripts/build_release.sh`    | archive → export → notarize → staple → zip into `releases/`  |
| `scripts/update_manifest.sh`  | regenerate `appcast.xml` + `aginol.json` from `releases/`    |
| `scripts/appcast_to_json.py`  | project newest feed item (+ SHA-256) into `aginol.json`      |

`build_release.sh` calls `update_manifest.sh` at the end, so the normal release
is one command:

```bash
Distribution/scripts/build_release.sh
```

Dry-run friendly: set `SKIP_NOTARIZE=1` for a local test build, which produces
a zip and a valid feed that just isn't distributable.
