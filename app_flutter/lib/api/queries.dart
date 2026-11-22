/// GraphQL documents, ported verbatim from the iOS client's .graphql files so
/// both clients hit the same Photoview server API surface.
library;

const _mediaItemFragment = r'''
fragment MediaItem on Media {
  id
  type
  title
  blurhash
  thumbnail {
    url
    width
    height
  }
  favorite
}
''';

const _albumItemFragment = r'''
fragment AlbumItem on Album {
  id
  title
  thumbnail {
    blurhash
    thumbnail {
      url
    }
  }
}
''';

const authorizeUserMutation = r'''
mutation AuthorizeUser($username: String!, $password: String!) {
  authorizeUser(username: $username, password: $password) {
    success
    status
    token
  }
}
''';

const initialSetupQuery = r'''
query InitialSetup {
  siteInfo {
    initialSetup
  }
}
''';

const timelineQuery =
    '''
query timeline(\$limit: Int!, \$offset: Int!, \$fromDate: Time) {
  # fromDate is the server's own way of starting the timeline further back:
  # "only fetch media that is older than this date". Null asks for the newest.
  myTimeline(paginate: {limit: \$limit, offset: \$offset}, fromDate: \$fromDate) {
    id
    date
    album {
      id
      title
    }
    ...MediaItem
  }
}
$_mediaItemFragment
''';

const myAlbumsQuery =
    '''
query myAlbums {
  myAlbums(order: {order_by: "title"}, onlyRoot: true, showEmpty: true) {
    ...AlbumItem
  }
}
$_albumItemFragment
''';

const singleAlbumQuery =
    '''
query albumViewSingleAlbum(\$albumID: ID!, \$limit: Int!, \$offset: Int!) {
  album(id: \$albumID) {
    id
    title
    media(paginate: {limit: \$limit, offset: \$offset}) {
      ...MediaItem
    }
    subAlbums {
      ...AlbumItem
    }
  }
}
$_mediaItemFragment
$_albumItemFragment
''';

// Paginated: resolving a thumbnail for every face group at once takes the
// server well over a minute on a sizeable library.
const myFacesThumbnailsQuery =
    r'''
query myFacesThumbnails($limit: Int!, $offset: Int!) {
  myFaceGroups(paginate: {limit: $limit, offset: $offset}) {
    ...faceGroupThumbnail
  }
}
''' +
    _faceGroupThumbnailFragment;

/// Fewest photos first. A document of its own rather than a variable on the
/// one above: a server without `countDirection` rejects the whole request for
/// naming it, even with a null value, so it is only sent where the
/// capability says the server has it.
const myFacesThumbnailsFewestFirstQuery =
    r'''
query myFacesThumbnailsFewestFirst($limit: Int!, $offset: Int!) {
  myFaceGroups(countDirection: ASC, paginate: {limit: $limit, offset: $offset}) {
    ...faceGroupThumbnail
  }
}
''' +
    _faceGroupThumbnailFragment;

/// [myFacesThumbnailsQuery] with whether each person still has a face nobody
/// has confirmed. A document of its own: a server without the face filter
/// rejects the whole request for naming it, so this one is only sent where
/// `Capability.faceVerification` says the server has it.
const myFacesThumbnailsWithStatusQuery =
    r'''
query myFacesThumbnailsWithStatus($limit: Int!, $offset: Int!) {
  myFaceGroups(paginate: {limit: $limit, offset: $offset}) {
    ...faceGroupThumbnail
    ...faceGroupStatus
  }
}
''' +
    _faceGroupThumbnailFragment +
    _faceGroupStatusFragment;

/// [myFacesThumbnailsFewestFirstQuery] with the status of
/// [myFacesThumbnailsWithStatusQuery].
const myFacesThumbnailsFewestFirstWithStatusQuery =
    r'''
query myFacesThumbnailsFewestFirstWithStatus($limit: Int!, $offset: Int!) {
  myFaceGroups(countDirection: ASC, paginate: {limit: $limit, offset: $offset}) {
    ...faceGroupThumbnail
    ...faceGroupStatus
  }
}
''' +
    _faceGroupThumbnailFragment +
    _faceGroupStatusFragment;

/// One unconfirmed face, if there is any — whether there is one is all the
/// list needs. Not `verifiedFaceCount` against `imageFaceCount`: the first
/// counts faces and the second photos, so a person twice on one photo would
/// come out confirmed with a face still unchecked. This costs the server what
/// the thumbnail's own one-face page costs.
const _faceGroupStatusFragment = r'''
fragment faceGroupStatus on FaceGroup {
  unverifiedFaces: imageFaces(paginate: {limit: 1}, filter: {verified: false}) {
    id
  }
}
''';

const _faceGroupThumbnailFragment = r'''
fragment faceGroupThumbnail on FaceGroup {
  id
  label
  imageFaceCount
  imageFaces(paginate: {limit: 1}) {
    id
    rectangle {
      minX
      maxX
      minY
      maxY
    }
    media {
      id
      thumbnail {
        url
        width
        height
      }
    }
  }
}
''';

const singlePersonQuery =
    '''
query singlePerson(\$faceGroupID: ID!) {
  faceGroup(id: \$faceGroupID) {
    id
    label
    imageFaces {
      id
      media {
        # imageFaces takes no ordering argument and the server applies none,
        # so the date is what the app sorts by.
        date
        ...MediaItem
      }
    }
  }
}
$_mediaItemFragment
''';

/// [singlePersonQuery] with whether each face is confirmed and waiting for
/// review. A document of its own: a server without those fields rejects the
/// whole request for naming them, so this one is only sent where
/// `Capability.faceVerification` says the server has them.
const singlePersonWithStatusQuery =
    '''
query singlePersonWithStatus(\$faceGroupID: ID!) {
  faceGroup(id: \$faceGroupID) {
    id
    label
    imageFaces {
      id
      verified
      needsReview
      media {
        date
        ...MediaItem
      }
    }
  }
}
$_mediaItemFragment
''';

/// Confirms every face on the photos — "everyone on here is right" — or takes
/// the confirmation back. Confirming also clears the review flag.
const setMediaFacesVerifiedMutation = r'''
mutation setMediaFacesVerified($mediaIDs: [ID!]!, $verified: Boolean!) {
  setMediaFacesVerified(mediaIDs: $mediaIDs, verified: $verified) {
    id
  }
}
''';

/// Confirms single faces, or takes the confirmation back — for the faces of
/// one person on the ticked photos, leaving the other people on them alone.
const setImageFacesVerifiedMutation = r'''
mutation setImageFacesVerified($imageFaceIDs: [ID!]!, $verified: Boolean!) {
  setImageFacesVerified(imageFaceIDs: $imageFaceIDs, verified: $verified) {
    id
  }
}
''';

/// Files the unconfirmed faces of the people again, comparing them with the
/// confirmed faces of everybody. With `dryRun` nothing changes and the answer
/// says what would.
///
/// Asks no `imageFaceCount`: the server recounts it per group and per change,
/// loading all of the user's albums every time. For a person with 7,500 faces
/// that turned a 3.5-second answer into four minutes.
const reclassifyFaceGroupsMutation = r'''
mutation reclassifyFaceGroups($faceGroupIDs: [ID!]!, $dryRun: Boolean!) {
  reclassifyFaceGroups(faceGroupIDs: $faceGroupIDs, dryRun: $dryRun) {
    checked
    kept
    moved
    unmatched
    conflicts
    verifiedSamples
    changes {
      imageFace {
        id
      }
      from {
        id
      }
      to {
        id
        label
      }
    }
  }
}
''';

/// Photos with a face waiting for review, newest first.
const mediaNeedingReviewQuery =
    '''
query mediaNeedingReview(\$limit: Int!, \$offset: Int!) {
  myMediaNeedingReview(paginate: {limit: \$limit, offset: \$offset}) {
    ...MediaItem
  }
}
$_mediaItemFragment
''';

/// Naming a person. A null label removes the name — the server's own way of
/// saying "no name", not an omission.
const setFaceGroupLabelMutation = r'''
mutation setFaceGroupLabel($faceGroupID: ID!, $label: String) {
  setFaceGroupLabel(faceGroupID: $faceGroupID, label: $label) {
    id
    label
  }
}
''';

/// Folds people together. The sources are gone afterwards, their faces filed
/// under the destination.
const combineFaceGroupsMutation = r'''
mutation combineFaceGroups($destinationFaceGroupID: ID!, $sourceFaceGroupIDs: [ID!]!) {
  combineFaceGroups(
    destinationFaceGroupID: $destinationFaceGroupID
    sourceFaceGroupIDs: $sourceFaceGroupIDs
  ) {
    id
    label
    imageFaceCount
  }
}
''';

/// Files single faces under another person — the photos of one person that
/// turned out to be someone else.
const moveImageFacesMutation = r'''
mutation moveImageFaces($imageFaceIDs: [ID!]!, $destinationFaceGroupID: ID!) {
  moveImageFaces(
    imageFaceIDs: $imageFaceIDs
    destinationFaceGroupID: $destinationFaceGroupID
  ) {
    id
    label
    imageFaceCount
  }
}
''';

/// The same move with the server's duplicate check turned off: the person may
/// then be on a photo more than once, as on a sheet of passport photos.
///
/// What the app sends for every move. Older servers do not know
/// `allowDuplicates` and refuse the whole request over it; the client then
/// falls back to [moveImageFacesMutation].
const moveImageFacesAllowingDuplicatesMutation = r'''
mutation moveImageFacesAllowingDuplicates($imageFaceIDs: [ID!]!, $destinationFaceGroupID: ID!) {
  moveImageFaces(
    imageFaceIDs: $imageFaceIDs
    destinationFaceGroupID: $destinationFaceGroupID
    allowDuplicates: true
  ) {
    id
    label
    imageFaceCount
  }
}
''';

/// Lifts single faces out into a face group of their own.
///
/// **Not to be sent with an empty list**: the server takes that as a request
/// and creates an empty group rather than refusing — measured against a live
/// instance, which answered with a brand new id.
const detachImageFacesMutation = r'''
mutation detachImageFaces($imageFaceIDs: [ID!]!) {
  detachImageFaces(imageFaceIDs: $imageFaceIDs) {
    id
    label
    imageFaceCount
  }
}
''';

/// Asks the server to match the unnamed faces against the named ones again.
///
/// Returns the faces it filed; the app only counts them, because what changed
/// is spread across the whole people list.
const recognizeUnlabeledFacesMutation = r'''
mutation recognizeUnlabeledFaces {
  recognizeUnlabeledFaces {
    id
  }
}
''';

const mediaGeoJsonQuery = r'''
query mediaGeoJson {
  myMediaGeoJson
}
''';

const placesClusterDetailsQuery =
    '''
query placesClusterDetails(\$ids: [ID!]!) {
  mediaList(ids: \$ids) {
    ...MediaItem
  }
}
$_mediaItemFragment
''';

/// The faces found on one photo, and whose they are.
///
/// Apart from [mediaDetailsQuery] so the details stay as quick as they were:
/// the faces are only asked for when the gallery is told to show them. A
/// server with face detection switched off answers an empty list.
const mediaFacesQuery = r'''
query mediaFaces($mediaID: ID!) {
  media(id: $mediaID) {
    id
    faces {
      id
      rectangle {
        minX
        maxX
        minY
        maxY
      }
      faceGroup {
        id
        label
        imageFaceCount
      }
    }
  }
}
''';

/// [mediaFacesQuery] with whether each face is confirmed and waiting for
/// review — only for a server that has those fields, as with
/// [singlePersonWithStatusQuery].
const mediaFacesWithStatusQuery = r'''
query mediaFacesWithStatus($mediaID: ID!) {
  media(id: $mediaID) {
    id
    faces {
      id
      verified
      needsReview
      rectangle {
        minX
        maxX
        minY
        maxY
      }
      faceGroup {
        id
        label
        imageFaceCount
      }
    }
  }
}
''';

const mediaDetailsQuery =
    '''
query mediaDetails(\$mediaID: ID!) {
  media(id: \$mediaID) {
    id
    title
    videoWeb {
      url
    }
    highRes {
      url
      width
      height
    }
    exif {
      camera
      maker
      lens
      dateShot
      exposure
      aperture
      iso
      focalLength
      flash
      exposureProgram
      coordinates {
        latitude
        longitude
      }
    }
    album {
      id
      title
      # The server's own breadcrumb, root first, ending in the album itself.
      path {
        id
        title
      }
    }
    shares {
      id
      token
    }
    downloads {
      title
      mediaUrl {
        url
        width
        height
        fileSize
      }
    }
    ...MediaItem
  }
}
$_mediaItemFragment
''';

/// Search with the limits as variables.
///
/// The server applies its own default of 10 each when they are omitted, and
/// treats 0 as unlimited — both measured against a live instance. The
/// `searchResultLimit` preference is *not* applied server-side to `search`, so
/// it is the client that reads the preference and passes it here.
const mediaSearchQuery =
    '''
query mediaSearch(\$query: String!, \$limitMedia: Int, \$limitAlbums: Int) {
  search(query: \$query, limitAlbums: \$limitAlbums, limitMedia: \$limitMedia) {
    query
    albums {
      ...AlbumItem
    }
    media {
      ...MediaItem
    }
  }
}
$_albumItemFragment
$_mediaItemFragment
''';

/// Children of many albums in one round trip.
///
/// `Album` has no `children` field of its own — verified against a live
/// instance — so a tree is built one level at a time. That is what this query
/// is for: asking about a whole level at once instead of one request per node.
const albumTreeChildrenQuery =
    '''
query albumTreeChildren(\$albumIds: [ID!]!) {
  albumTreeChildren(albumIds: \$albumIds) {
    albumId
    children {
      ...AlbumItem
    }
  }
}
$_albumItemFragment
''';

/// What the scanner is working on right now.
///
/// A snapshot, not a stream: there is no subscription for it, so the app polls
/// while anything is running. Admins see every job, everyone else only jobs for
/// albums they own — so an empty queue can also mean "nothing of yours".
const scannerQueueStatusQuery = r'''
query scannerQueueStatus {
  scannerQueueStatus {
    album {
      id
      title
    }
    status
  }
}
''';

/// Queues an album and its sub-albums for scanning.
///
/// Returns as soon as the work is queued — measured at about 100 ms against a
/// live instance — so this needs no special timeout. What lands in the queue
/// are the *sub-albums*, which is why the queue may never show the album that
/// was asked for.
const scanAlbumMutation = r'''
mutation scanAlbum($albumId: ID!) {
  scanAlbum(albumId: $albumId) {
    success
    message
  }
}
''';

/// [scanAlbumMutation] taking in only what is new: the album's own media and
/// the direct sub-directories that are not albums yet, each with everything
/// below it. Existing sub-albums are neither scanned nor removed. A document
/// of its own, sent only where `Capability.scanAlbumNewSubAlbums` says the
/// server knows the argument.
const scanAlbumNewSubAlbumsMutation = r'''
mutation scanAlbumNewSubAlbums($albumId: ID!) {
  scanAlbum(albumId: $albumId, onlyNewSubAlbums: true) {
    success
    message
  }
}
''';

/// Cancels one album's job. False means there was no job for that album.
const cancelScanJobMutation = r'''
mutation cancelScanJob($albumId: ID!) {
  cancelScanJob(albumId: $albumId)
}
''';

/// Cancels everything the caller is allowed to cancel, returning how many.
const cancelAllScanJobsMutation = r'''
mutation cancelAllScanJobs {
  cancelAllScanJobs
}
''';

/// Reads the preferences the app cares about.
///
/// `language` is read even though the app does not use it, because it has to
/// be written back — see [changeUserPreferencesMutation].
///
/// `showAlbumTree` is included only when the server has it, which is why this
/// is built rather than a constant. Asking for it unconditionally would tie
/// two separate capabilities together: on a server that has
/// `searchResultLimit` but not `showAlbumTree`, one missing field would fail
/// the whole document and take the search limit down with it.
String userPreferencesQuery({bool withAlbumTree = false}) =>
    '''
query myUserPreferences {
  myUserPreferences {
    id
    language
    searchResultLimit${withAlbumTree ? '\n    showAlbumTree' : ''}
  }
}
''';

/// Writes user preferences.
///
/// **Every field has to be sent every time.** This mutation replaces the whole
/// preferences record rather than patching it: measured against a live
/// instance, writing only `searchResultLimit` reset a `language` of `English`
/// to null. So an omitted argument is not "leave alone", it is "clear" — which
/// is also the only way to clear a field, since the server rejects a negative
/// limit outright ("search result limit must not be negative").
///
/// Same conditional shape as [userPreferencesQuery], and for the same reason:
/// a server without `showAlbumTree` must still be able to store a search
/// limit.
String changeUserPreferencesMutation({bool withAlbumTree = false}) =>
    '''
mutation changeUserPreferences(
  \$language: String
  \$searchResultLimit: Int${withAlbumTree ? '\n  \$showAlbumTree: Boolean' : ''}
) {
  changeUserPreferences(
    language: \$language
    searchResultLimit: \$searchResultLimit${withAlbumTree ? '\n    showAlbumTree: \$showAlbumTree' : ''}
  ) {
    id
    language
    searchResultLimit${withAlbumTree ? '\n    showAlbumTree' : ''}
  }
}
''';

const shareMediaMutation = r'''
mutation shareMedia($id: ID!) {
  shareMedia(mediaId: $id) {
    id
    token
  }
}
''';

const deleteShareTokenMutation = r'''
mutation deleteShareToken($token: String!) {
  deleteShareToken(token: $token) {
    id
    token
  }
}
''';
