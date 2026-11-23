# Changelog

Changes to the Flutter client in [`app_flutter/`](./app_flutter). The SwiftUI
client in `Photoview/` is unchanged and not versioned here.

Every change raises `version:` in [`app_flutter/pubspec.yaml`](./app_flutter/pubspec.yaml)
— the name and the build number after the `+` — and gets an entry here. The app
shows the running version under Settings › Info.

## 1.3.0 (11) — 2026-11-23

Merging unnamed people whose faces look alike, for a server that knows
`mergeSimilarUnlabeledFaceGroups`. Against any other server nothing changes.

### Added

- **Merge similar unnamed** (People tab): the server compares the faces of
  every unnamed person without a confirmed face and proposes which of them
  are one person. Each proposal shows as its faces. A tap on a face leaves
  its group out, a long press shows its photo. Proposals are merged one by
  one or all at once, exactly as shown — groups left out stay out, and
  proposals turned down are not merged with the rest. A turned-down proposal
  is remembered on the device for this account and stays hidden until "Show
  again". Opening the proposals changes nothing; the button explains this
  first. Searching again after merging can bring new proposals.
- **Merged photos on the review list.** On a server with
  `setImageFacesNeedsReview`, the faces of every merged proposal are flagged
  for review, so their photos — which often hold other faces still to sort
  out — turn up on the review list. If only the flagging fails, the message
  says so and a retry flags them without merging again.

### Changed

- The photo's tick clears the review flag of unnamed faces with
  `setImageFacesNeedsReview` where the server has it, instead of confirming
  them and taking it back at once.
- A server feature probed with a mutation now counts as present only when
  its own mutation was validated. The sentinel refused on one mutation used
  to count for every feature probed that way.

## 1.2.0 (9) — 2026-11-23

Confirming faces and re-identifying people, for a server that knows which
faces a person has confirmed. Against any other server nothing changes.

### Added

- **Confirming faces.** With the faces shown on a photo, a new button says
  "everyone named on this photo is right" and confirms every face filed under
  a name; pressed again once all are confirmed, it takes that back. Faces
  without a name stay unconfirmed: to the server, a confirmed face without a
  name is someone of their own, never moved by a run again and pulling
  similar faces in — not knowing a face says neither. Where such a face waits
  for review, the button only marks it as looked at. Confirmed faces are
  framed green and their names carry a ✓, faces an automatic run placed and
  nobody has checked are framed amber. A face filed under someone else by hand
  counts as confirmed by itself.
- **Keeping an unknown face as a person of their own.** Tapping a face
  without a name offers to confirm it without naming it, so that the next
  matching run gathers similar faces to it and the person can be named later.
  The same entry takes it back. For the only face of an unnamed person, the
  dialog no longer offers to take it out without a name, which would only
  have moved it into another unnamed person of one. The dialog is also as
  tall as the screen allows, so the people below its entries are not
  squeezed into a single line.
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
- **"More than once on a photo"**, a filter on a person's page for the photos
  on which more than one face is filed under that person. Often one of them
  is someone else; on a sheet of passport photos or in a mirror, it is right.
  Their faces are shown when such a photo is opened. The filter appears only
  for people who have such photos.
- **A green tick on the People tab** for every person whose faces are all
  confirmed, and a button beside the review list that keeps only the named
  people without it — those with a face still to check. Confirming faces
  updates the ticks.
- **Scanning only what is new in an album.** On a server that knows
  `onlyNewSubAlbums`, the scan button asks: "only what is new" reads the
  album's own photos and takes in folders that are not albums yet — a new
  month in a year album — without going through the sub-albums that are
  there; "everything" scans the album with all its sub-albums, as before.
  Against any other server the button scans everything at once, as it did.
  The app finds out with a request the server refuses before running it, so
  asking never starts a scan.
- **Moving a face onto a photo the person is on already.** A move by hand is
  the user's decision, so the app sends it with the server's duplicate check
  turned off (`allowDuplicates`): a sheet of passport photos, a mirror or a
  photographed album page can hold one person more than once. A server
  without that switch gets the plain move, under its own check.
- **A person that is gone** — merged into someone else elsewhere while the app
  still listed them — is now reported as such, in the app's language, when it
  is opened, moved to, merged into or named. Servers since 7a4ece2 refuse it
  by name; before, they answered with an empty person.

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
- The frames around faces no longer darken the face inside them. Their
  shadow, there to keep a frame visible on a bright photo, was also painted
  within the frame; it now falls only outside.
- A face can be tapped on a zoomed photo too. The tap was placed on the
  photo with the zoom the photo view reported, which after a double tap
  still held the zoom from before; it is now mapped onto the photo as drawn.
  And on a zoomed photo the photo view took a tap for panning as soon as the
  finger moved a pixel, which a fingertip always does, and dropped it. The
  gallery now tells taps apart itself, from the finger's own movements: one
  finger, moved less than the usual touch slop, not followed by a second tap.

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
