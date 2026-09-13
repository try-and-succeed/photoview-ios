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

const timelineQuery = '''
query timeline(\$limit: Int!, \$offset: Int!) {
  myTimeline(paginate: {limit: \$limit, offset: \$offset}) {
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

const myAlbumsQuery = '''
query myAlbums {
  myAlbums(order: {order_by: "title"}, onlyRoot: true, showEmpty: true) {
    ...AlbumItem
  }
}
$_albumItemFragment
''';

const singleAlbumQuery = '''
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
const myFacesThumbnailsQuery = r'''
query myFacesThumbnails($limit: Int!, $offset: Int!) {
  myFaceGroups(paginate: {limit: $limit, offset: $offset}) {
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
}
''';

const singlePersonQuery = '''
query singlePerson(\$faceGroupID: ID!) {
  faceGroup(id: \$faceGroupID) {
    id
    label
    imageFaces {
      id
      media {
        ...MediaItem
      }
    }
  }
}
$_mediaItemFragment
''';

const mediaGeoJsonQuery = r'''
query mediaGeoJson {
  myMediaGeoJson
}
''';

const placesClusterDetailsQuery = '''
query placesClusterDetails(\$ids: [ID!]!) {
  mediaList(ids: \$ids) {
    ...MediaItem
  }
}
$_mediaItemFragment
''';

const mediaDetailsQuery = '''
query mediaDetails(\$mediaID: ID!) {
  media(id: \$mediaID) {
    id
    title
    videoWeb {
      url
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
const mediaSearchQuery = '''
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
const userPreferencesQuery = r'''
query myUserPreferences {
  myUserPreferences {
    id
    language
    searchResultLimit
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
const changeUserPreferencesMutation = r'''
mutation changeUserPreferences($language: String, $searchResultLimit: Int) {
  changeUserPreferences(
    language: $language
    searchResultLimit: $searchResultLimit
  ) {
    id
    language
    searchResultLimit
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
