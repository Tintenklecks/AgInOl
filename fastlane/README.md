fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Generate new localized screenshots

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download existing metadata (descriptions, keywords, etc.) from App Store Connect

### ios download_appstore_screenshots

```sh
[bundle exec] fastlane ios download_appstore_screenshots
```

Download existing screenshots from App Store Connect

### ios download_all

```sh
[bundle exec] fastlane ios download_all
```

Download everything currently live on App Store Connect (metadata + screenshots)

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload all local metadata to App Store Connect

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload all local screenshots to App Store Connect

### ios upload_all

```sh
[bundle exec] fastlane ios upload_all
```

Upload all local metadata and screenshots to App Store Connect

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
