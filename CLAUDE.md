# Working rules for this repository

These apply to the Flutter client in `app_flutter/`. The SwiftUI client in
`Photoview/` stays untouched.

## Language

- Write all comments in the source code in English.
- Write all Markdown files in English.

## Commits and pushes

- **Commit without asking.** Decide when to commit yourself, at the latest after
  every finished, tested state.
- **Push only on request.**

## Versions and changelog

- **Every change** gets an entry in [`CHANGELOG.md`](./CHANGELOG.md) and a new
  version in [`app_flutter/pubspec.yaml`](./app_flutter/pubspec.yaml): raise the
  version name (`1.1.0`) and always the build number after the `+` (`+2`). The
  build number becomes Android's `versionCode` and must only ever go up.
- **One version name per pull request**, not per commit: the first commit of
  a branch raises the version name, and each later commit on it adds its line
  to the same changelog entry.
- **One build number per APK**: every commit raises the build number after
  the `+`, even within a pull request, so no two APKs handed out carry the
  same number. The changelog heading names the latest build of that version,
  e.g. `## 1.2.0 (5)`.
- `test/about_test.dart` fails when the version in `pubspec.yaml` has no
  heading in `CHANGELOG.md`.

## Builds

- **Build a release APK after every state**, so it can be handed to other
  phones, and name its path:

  ```sh
  cd app_flutter
  flutter build apk --release
  # → app_flutter/build/app/outputs/flutter-apk/app-release.apk
  ```

## Info screen

- The app's **Info** entry (Settings › Info) always shows the current version
  number. It comes from `version:` in `pubspec.yaml`, read at run time through
  `package_info_plus` (`appVersionProvider` in `lib/state/app_version.dart`) —
  the counterpart of Android's `BuildConfig.VERSION_NAME`. Never hard-code it.
