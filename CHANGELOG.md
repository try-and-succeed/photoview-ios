# Changelog

Changes to the Flutter client in [`app_flutter/`](./app_flutter). The SwiftUI
client in `Photoview/` is unchanged and not versioned here.

Every change raises `version:` in [`app_flutter/pubspec.yaml`](./app_flutter/pubspec.yaml)
— the name and the build number after the `+` — and gets an entry here. The app
shows the running version under Settings › Info.

## 1.1.1 (3) — 2026-11-21

Fixes from a CodeRabbit review of pull requests #23 to #27.

### Fixed

- A face as tall as the photo no longer loses its name: with no room above or
  below, the name is kept on the photo, over the face, instead of being placed
  off it and cut away.
- The people list no longer keeps loading pages for a fetch that a newer one
  has already replaced — after two moves in quick succession, a long list sent
  dozens of needless requests.
- Moving photos to a new person: when they were taken out but naming the new
  person failed for any reason, not only an untrusted certificate, the message
  now says where the photos are and offers to try naming it again. Before, the
  new person stayed unnamed with no way back, as the photos were no longer
  there to be picked again.
- A new person is named only on the account it was made on. Signing in to
  another server while the photos were being taken out could otherwise have
  renamed a group with the same number there.

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
