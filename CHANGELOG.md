# Changelog

Changes to the Flutter client in [`app_flutter/`](./app_flutter). The SwiftUI
client in `Photoview/` is unchanged and not versioned here.

Every change raises `version:` in [`app_flutter/pubspec.yaml`](./app_flutter/pubspec.yaml)
— the name and the build number after the `+` — and gets an entry here. The app
shows the running version under Settings › Info.

## 1.2.0 (4) — 2026-11-21

Confirming faces and re-identifying people, for a server that knows which
faces a person has confirmed. Against any other server nothing changes.

### Added

- **Confirming faces.** With the faces shown on a photo, a new button says
  "everyone on this photo is right" and confirms every face on it; pressed
  again once all are confirmed, it takes that back. Confirmed faces are framed
  green and their names carry a ✓, faces an automatic run placed and nobody has
  checked are framed amber. A face filed under someone else by hand counts as
  confirmed by itself.
- **Filters on a person's page:** all, confirmed, unconfirmed and to review,
  each with its count, and a mark on each tile that is confirmed or waits for
  review. Photos opened from the unconfirmed or review filter show their faces
  at once. Ticked photos can be confirmed together, which confirms only this
  person's faces on them.
- **Re-identifying a person.** Their unconfirmed faces are compared with the
  confirmed faces of everybody. The server first says what it would do — how
  many stay, who the others go to, how many match nobody and become people of
  their own — and only a yes to that changes anything. Every face it looked at
  then waits for review.
- **A review list** (People › To review): every photo with a face waiting for
  review, newest first, across all people, so the faces a run sent elsewhere
  can be checked too. It is also offered right after re-identifying.
- **Finding a person by name** on the People tab: the magnifier opens a name
  field, and the list keeps only the people whose name contains what is typed.
  Back or the cross closes it and shows everybody again.

### Changed

- The People tab's buttons for matching unnamed faces and for the review list
  first say what they do, and act only after a yes. Before, a tap on the icon
  started the match at once.

### Fixed

- Re-identifying a person with thousands of faces no longer gives up after a
  minute without a word. The preview asked the server for each person's face
  count, which it recounts for every single face: for 7,500 faces that took
  four minutes instead of 3.5 seconds. The app no longer asks for it, and it
  now waits up to five minutes for re-identifying.

## 1.1.1 (3) — 2026-11-21

Fixes from a CodeRabbit review of pull requests #23 to #27.

### Fixed

- A face as tall as the photo no longer loses its name: with no room above or
  below, the name is kept on the photo, over the face, instead of being placed
  off it and cut away.
- The people list no longer keeps loading pages for a fetch that a newer one
  has already replaced — after two moves in quick succession, a long list sent
  dozens of needless requests. Nor can such a fetch, refused "fewest first" by
  the server, switch the order of the one that replaced it, which mixed two
  orders in one list.
- Moving photos to a new person: when they were taken out but naming the new
  person failed for any reason, not only an untrusted certificate, the message
  now says where the photos are and offers to try naming it again. Before, the
  new person stayed unnamed with no way back, as the photos were no longer
  there to be picked again.
- Moving, splitting and naming send nothing to an account signed in to after
  the action started — neither right away nor when tried again. Signing in to
  another server meanwhile could otherwise have moved, split or renamed
  whatever has the same numbers there. The message then offers no retry, as it
  could only fail again.
- A server that splits faces off without naming the new group no longer
  produces "Moved to …" for a name that was never given; the message says the
  photos were split off as a new person.
- A person's page drops photos from the selection once they are no longer
  there. After a move that went half through, it kept counting them as
  selected, and Back only ended the picking.
- "Retry" and "Review certificate" on a message whose page has been left
  meanwhile now say that it cannot be tried again from there, instead of
  doing nothing.
- Filing faces from the photo view or a person's page: the answer is shown even
  when that screen was closed while the request ran. A move that went half
  through was otherwise never reported.

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
