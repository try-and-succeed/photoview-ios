/// GraphQL documents, ported verbatim from the iOS client's .graphql files so
/// both clients hit the same Photoview server API surface.
library;

const _mediaItemFragment = r'''
fragment MediaItem on Media {
  id
  type
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

const mediaSearchQuery = '''
query mediaSearch(\$query: String!) {
  search(query: \$query, limitAlbums: 6, limitMedia: 12) {
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
