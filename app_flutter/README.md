# Photoview — Flutter client

A Flutter port of the Photoview iOS client, targeting Android and iOS from one
codebase.

## Origin and licence

This is a **modified version** of the Photoview iOS client
([photoview/photoview-ios](https://github.com/photoview/photoview-ios)),
originally written in SwiftUI by Viktor Strate Kløvedal (2021–2022).

The port began in September 2026. The Swift sources remain in `../Photoview`
for reference; nothing in them was changed.

Licensed under the **GNU General Public License v3**, the same licence as the
original — see [`../LICENSE`](../LICENSE). That means this port, and anything
derived from it, must stay open under GPL-3, and anyone given a binary is
entitled to the corresponding source.

The GraphQL operations in `lib/api/queries.dart` are taken verbatim from the
iOS client's `.graphql` files, so both clients speak to the server identically.
The Dart code is newly written, following the behaviour of the Swift original.

## Differences from the iOS original

Same server API — all thirteen GraphQL operations are unchanged.

Added:

- **Saved servers.** Instance, username and auth token are remembered per
  server, so switching is one tap. Passwords are never stored.
- **Private certificate authorities.** A self-hosted instance behind its own
  CA can be used either by accepting one certificate after seeing its SHA-256
  fingerprint, or by importing the CA itself — which is what makes an authority
  like Caddy's internal one usable, since it reissues certificates twice a day.
- **Media in search results.** The iOS client fetched them but left the grid
  commented out, so only albums were shown.
- **Paginated face groups.** Requesting every group at once takes the server
  well over a minute on a sizeable library; the iOS client had the same query
  but no request timeout, so it simply waited.
- Pull-to-refresh, a favourite marker on thumbnails (the field was fetched but
  never shown), an image cache that can be cleared, and error messages that
  name the cause — an untrusted certificate reads differently from an
  unreachable host.

Dropped:

- Per-tab accent colours. They were defined only for light mode; in dark mode
  the original used white for every tab.

## Building

Requires the Flutter SDK (developed against 3.47.4).

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # Android
flutter build ios --no-codesign # iOS, needs macOS and Xcode
```

### Local notes

`android/gradle.properties` sets `kotlin.incremental=false`. That works around
a machine where the Kotlin compiler could not close its incremental caches
("Could not close incremental caches"), which failed plugin compilation. It
only costs some build time and can be removed if your machine is unaffected.

Plain HTTP is permitted on both platforms — via `network_security_config.xml`
on Android and `NSAllowsArbitraryLoads` on iOS — because self-hosted instances
are commonly served over HTTP on a LAN, and the address is entered at runtime
so no single host can be allowlisted. The Swift client allowed the same.

## Status

Verified against a live Photoview instance on an Android device: sign-in,
timeline, albums, the places map with clustering and reverse geocoding, people
with face crops, media details with EXIF, downloads, share links, search and
video playback.

The iOS side is unverified — it has never been built, as that needs macOS.
