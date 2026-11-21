# Changelog

Changes to the Flutter client in [`app_flutter/`](./app_flutter). The SwiftUI
client in `Photoview/` is unchanged and not versioned here.

Every change raises `version:` in [`app_flutter/pubspec.yaml`](./app_flutter/pubspec.yaml)
— the name and the build number after the `+` — and gets an entry here. The app
shows the running version under Settings › Info.

## 1.1.0 (2) — 2026-11-21

### Added

- **Settings › Info** shows the app's version and build number, read from the
  build rather than written into the code, and opens the About dialog with the
  licence and the licences of the packages the app is built from.
- This changelog. From here on every change raises the version and is listed
  here; a test fails when the version in `pubspec.yaml` has no entry.

## 1.0.0 (1)

Everything up to and including pull request #26, before versions were kept.
The README describes what the client does; in short:

- Sign-in with saved servers, private certificate authorities and pinned
  certificates.
- Timeline, albums with an album tree, places map, search with media,
  full-resolution photo view with EXIF, slideshow, downloads and sharing.
- Scanner controls.
- People: naming, merging, matching the unnamed, sorting by name or photo count
  either way round, moving faces from a person's page or from the photo with
  its face frames, and a name filter in the person picker. Every move is
  confirmed first.
- Translations in the 18 languages of the Photoview web client.
