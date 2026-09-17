# iOS client for Photoview

[![Download_on_the_App_Store_Badge_US-UK_RGB_blk_092917](https://user-images.githubusercontent.com/4233458/152636339-f1109755-a116-4ebc-9508-7e297adab081.svg)](https://apps.apple.com/dk/app/photoview-media-gallery/id1578380271)


![screenshots](./screenshots/screenshot.png)

## A second client, for iOS and Android

This fork adds a **rewritten client in [`app_flutter/`](./app_flutter)**, built
with Flutter so that a single codebase serves both iOS and Android. It talks to
the same Photoview server: the GraphQL operations are taken verbatim from the
SwiftUI client's `.graphql` files, so both clients speak to the server
identically.

Beyond the original it offers saved servers, private certificate authorities,
media in search results, an album tree, scanner controls, a full-resolution
gallery with a presentation mode, downloads, and translations in the 18
languages of the Photoview web client.

The SwiftUI app in [`Photoview/`](./Photoview) is **unchanged** and stays the
reference the port follows. The App Store link above is for the original iOS
client; the Flutter client is not published to any store and is built from
source.

See [`app_flutter/README.md`](./app_flutter/README.md) for what differs from
the original in detail, and for how to build it.
