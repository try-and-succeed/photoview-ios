enum MediaType { photo, video }

/// The server's `MediaType` enum spells its values `Photo` and `Video`, not
/// the SCREAMING_CASE that GraphQL enums usually use. Matched case-insensitively
/// so either spelling works.
MediaType _mediaTypeFrom(String? raw) =>
    raw?.toLowerCase() == 'video' ? MediaType.video : MediaType.photo;

int _asInt(Object? v) => (v as num?)?.toInt() ?? 0;

double? _asDouble(Object? v) => (v as num?)?.toDouble();

class Thumbnail {
  final String url;
  final int width;
  final int height;

  const Thumbnail({required this.url, this.width = 0, this.height = 0});

  factory Thumbnail.fromJson(Map<String, dynamic> json) => Thumbnail(
    url: json['url'] as String,
    width: _asInt(json['width']),
    height: _asInt(json['height']),
  );

  double get aspectRatio => height == 0 ? 1 : width / height;
}

class MediaItem {
  final String id;
  final MediaType type;

  /// Usually the file name. Needed wherever media is listed as text rather
  /// than as a picture, which is how large result sets are shown.
  final String title;
  final String? blurhash;
  final Thumbnail? thumbnail;
  final bool favorite;

  const MediaItem({
    required this.id,
    required this.type,
    this.title = '',
    this.blurhash,
    this.thumbnail,
    this.favorite = false,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final thumb = json['thumbnail'] as Map<String, dynamic>?;
    return MediaItem(
      id: json['id'].toString(),
      type: _mediaTypeFrom(json['type'] as String?),
      title: json['title'] as String? ?? '',
      blurhash: json['blurhash'] as String?,
      thumbnail: thumb == null ? null : Thumbnail.fromJson(thumb),
      favorite: json['favorite'] as bool? ?? false,
    );
  }

  MediaItem copyWith({Thumbnail? thumbnail, bool? favorite}) => MediaItem(
    id: id,
    type: type,
    title: title,
    blurhash: blurhash,
    thumbnail: thumbnail ?? this.thumbnail,
    favorite: favorite ?? this.favorite,
  );
}

class AlbumItem {
  final String id;
  final String title;
  final String? thumbnailUrl;
  final String? blurhash;

  const AlbumItem({
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.blurhash,
  });

  factory AlbumItem.fromJson(Map<String, dynamic> json) {
    final cover = json['thumbnail'] as Map<String, dynamic>?;
    final coverThumb = cover?['thumbnail'] as Map<String, dynamic>?;
    return AlbumItem(
      id: json['id'].toString(),
      title: json['title'] as String? ?? '',
      thumbnailUrl: coverThumb?['url'] as String?,
      blurhash: cover?['blurhash'] as String?,
    );
  }
}

class TimelineMedia {
  final MediaItem media;
  final DateTime date;
  final String albumId;
  final String albumTitle;

  const TimelineMedia({
    required this.media,
    required this.date,
    required this.albumId,
    required this.albumTitle,
  });

  factory TimelineMedia.fromJson(Map<String, dynamic> json) {
    final album = json['album'] as Map<String, dynamic>? ?? const {};
    return TimelineMedia(
      media: MediaItem.fromJson(json),
      date: DateTime.parse(json['date'] as String).toLocal(),
      albumId: album['id']?.toString() ?? '',
      albumTitle: album['title'] as String? ?? '',
    );
  }
}

/// A run of consecutive timeline media sharing the same album and calendar day.
class TimelineGroup {
  final String albumId;
  final String albumTitle;
  final DateTime day;
  final List<MediaItem> media;

  const TimelineGroup({
    required this.albumId,
    required this.albumTitle,
    required this.day,
    required this.media,
  });
}

class FaceRectangle {
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  const FaceRectangle({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  factory FaceRectangle.fromJson(Map<String, dynamic> json) => FaceRectangle(
    minX: _asDouble(json['minX']) ?? 0,
    maxX: _asDouble(json['maxX']) ?? 1,
    minY: _asDouble(json['minY']) ?? 0,
    maxY: _asDouble(json['maxY']) ?? 1,
  );

  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
  double get width => maxX - minX;
  double get height => maxY - minY;
}

class FaceGroup {
  final String id;
  final String? label;
  final int imageFaceCount;
  final FaceRectangle? rectangle;
  final Thumbnail? thumbnail;

  const FaceGroup({
    required this.id,
    this.label,
    this.imageFaceCount = 0,
    this.rectangle,
    this.thumbnail,
  });

  factory FaceGroup.fromJson(Map<String, dynamic> json) {
    final faces = json['imageFaces'] as List<dynamic>? ?? const [];
    final first = faces.isEmpty ? null : faces.first as Map<String, dynamic>;
    final rect = first?['rectangle'] as Map<String, dynamic>?;
    final media = first?['media'] as Map<String, dynamic>?;
    final thumb = media?['thumbnail'] as Map<String, dynamic>?;

    return FaceGroup(
      id: json['id'].toString(),
      label: json['label'] as String?,
      imageFaceCount: _asInt(json['imageFaceCount']),
      rectangle: rect == null ? null : FaceRectangle.fromJson(rect),
      thumbnail: thumb == null ? null : Thumbnail.fromJson(thumb),
    );
  }
}

/// One photo of a person, with the detections that put it there.
///
/// The server files a person's photos as `imageFace` rows, and it is those
/// ids — not the media ids — that `moveImageFaces` and `detachImageFaces`
/// take. A photo the detector found the same person in twice has two of them,
/// so this is a list: the tile means "this photo's faces **in this group**",
/// and all of them travel together.
class PersonPhoto {
  final MediaItem media;
  final List<String> faceIds;

  const PersonPhoto({required this.media, required this.faceIds});
}

/// Where a photo was taken, as the server reports it.
///
/// Its own type rather than two loose numbers: half a position is no
/// position, and the two are only ever read together.
class MediaCoordinates {
  final double latitude;
  final double longitude;

  const MediaCoordinates({required this.latitude, required this.longitude});

  /// Reads a position, or null if there is not a whole and possible one.
  ///
  /// The range is checked because nothing upstream checks it: the numbers come
  /// from a photo's own metadata, and a file with a broken GPS block can carry
  /// a latitude of 91. Shown as a position it would read as a place on earth,
  /// which it is not — better no row than a wrong one.
  static MediaCoordinates? fromJson(Map<String, dynamic>? json) {
    final latitude = _asDouble(json?['latitude']);
    final longitude = _asDouble(json?['longitude']);
    if (latitude == null || longitude == null) return null;
    if (latitude.abs() > 90 || longitude.abs() > 180) return null;

    return MediaCoordinates(latitude: latitude, longitude: longitude);
  }
}

class MediaExif {
  final String? camera;
  final String? maker;
  final String? lens;
  final String? dateShot;
  final double? exposure;
  final double? aperture;
  final int? iso;
  final double? focalLength;
  final double? flash;
  final int? exposureProgram;

  /// Null for a photo the camera did not place, which is most of them on a
  /// camera without GPS.
  final MediaCoordinates? coordinates;

  const MediaExif({
    this.camera,
    this.maker,
    this.lens,
    this.dateShot,
    this.exposure,
    this.aperture,
    this.iso,
    this.focalLength,
    this.flash,
    this.exposureProgram,
    this.coordinates,
  });

  factory MediaExif.fromJson(Map<String, dynamic> json) => MediaExif(
    camera: json['camera'] as String?,
    maker: json['maker'] as String?,
    lens: json['lens'] as String?,
    dateShot: json['dateShot'] as String?,
    exposure: _asDouble(json['exposure']),
    aperture: _asDouble(json['aperture']),
    iso: (json['iso'] as num?)?.toInt(),
    focalLength: _asDouble(json['focalLength']),
    flash: _asDouble(json['flash']),
    exposureProgram: (json['exposureProgram'] as num?)?.toInt(),
    coordinates: MediaCoordinates.fromJson(
      json['coordinates'] as Map<String, dynamic>?,
    ),
  );
}

class MediaShare {
  final String id;
  final String token;

  const MediaShare({required this.id, required this.token});

  factory MediaShare.fromJson(Map<String, dynamic> json) =>
      MediaShare(id: json['id'].toString(), token: json['token'] as String);
}

class MediaDownload {
  final String title;
  final String url;
  final int width;
  final int height;
  final int fileSize;

  const MediaDownload({
    required this.title,
    required this.url,
    required this.width,
    required this.height,
    required this.fileSize,
  });

  factory MediaDownload.fromJson(Map<String, dynamic> json) {
    final media = json['mediaUrl'] as Map<String, dynamic>? ?? const {};
    return MediaDownload(
      title: json['title'] as String? ?? '',
      url: media['url'] as String? ?? '',
      width: _asInt(media['width']),
      height: _asInt(media['height']),
      fileSize: _asInt(media['fileSize']),
    );
  }
}

/// Where a photo sits in the library: its album, and the albums above it.
///
/// The server's `path` is the ancestors only, nearest parent first, and it
/// stops at the highest album the user owns — a shared album does not disclose
/// the folders above it. [crumbs] puts that the way it reads, root first and
/// ending in the album the photo is in.
class MediaAlbum {
  final String id;
  final String title;
  final List<AlbumRef> ancestors;

  const MediaAlbum({
    required this.id,
    required this.title,
    this.ancestors = const [],
  });

  List<AlbumRef> get crumbs => [
    ...ancestors.reversed,
    AlbumRef(id: id, title: title),
  ];

  factory MediaAlbum.fromJson(Map<String, dynamic> json) => MediaAlbum(
    id: json['id'].toString(),
    title: json['title'] as String? ?? '',
    ancestors: (json['path'] as List<dynamic>? ?? const [])
        .map((e) => AlbumRef.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// An album named only well enough to show it and open it.
class AlbumRef {
  final String id;
  final String title;

  const AlbumRef({required this.id, required this.title});

  factory AlbumRef.fromJson(Map<String, dynamic> json) => AlbumRef(
    id: json['id'].toString(),
    title: json['title'] as String? ?? '',
  );
}

class MediaDetails {
  final MediaItem media;
  final String title;
  final String? videoWebUrl;

  /// Null when the server did not send one — an older server, or a share link
  /// that resolves the media without its album.
  final MediaAlbum? album;

  /// The largest rendition a screen can display. For a JPEG this is the
  /// original file itself — measured: same URL and size as the "Original"
  /// download — so it can be large. Only asked for here, one item at a time,
  /// rather than in the grid queries that fetch hundreds of items at once.
  final Thumbnail? highRes;
  final MediaExif? exif;
  final List<MediaShare> shares;
  final List<MediaDownload> downloads;

  const MediaDetails({
    required this.media,
    required this.title,
    this.album,
    this.videoWebUrl,
    this.highRes,
    this.exif,
    this.shares = const [],
    this.downloads = const [],
  });

  factory MediaDetails.fromJson(Map<String, dynamic> json) {
    final album = json['album'] as Map<String, dynamic>?;
    final exif = json['exif'] as Map<String, dynamic>?;
    final videoWeb = json['videoWeb'] as Map<String, dynamic>?;
    final highRes = json['highRes'] as Map<String, dynamic>?;
    final downloads = (json['downloads'] as List<dynamic>? ?? const [])
        .map((e) => MediaDownload.fromJson(e as Map<String, dynamic>))
        .toList();

    // Largest file first, matching the iOS ordering.
    downloads.sort((a, b) => b.fileSize.compareTo(a.fileSize));

    return MediaDetails(
      media: MediaItem.fromJson(json),
      title: json['title'] as String? ?? '',
      album: album == null ? null : MediaAlbum.fromJson(album),
      videoWebUrl: videoWeb?['url'] as String?,
      highRes: highRes == null || highRes['url'] == null
          ? null
          : Thumbnail.fromJson(highRes),
      exif: exif == null ? null : MediaExif.fromJson(exif),
      shares: (json['shares'] as List<dynamic>? ?? const [])
          .map((e) => MediaShare.fromJson(e as Map<String, dynamic>))
          .toList(),
      downloads: downloads,
    );
  }
}

/// What the scanner is doing with one album.
///
/// The server has exactly two states. [unknown] is the app's own, for a value
/// added to the enum later — an unrecognised status must render as "busy",
/// not crash the screen.
enum ScannerJobStatus { running, queued, unknown }

/// One album in the scanner queue.
class ScannerJob {
  final String albumId;
  final String albumTitle;
  final ScannerJobStatus status;

  const ScannerJob({
    required this.albumId,
    required this.albumTitle,
    required this.status,
  });

  factory ScannerJob.fromJson(Map<String, dynamic> json) {
    final album = json['album'] as Map<String, dynamic>? ?? const {};

    return ScannerJob(
      albumId: album['id']?.toString() ?? '',
      albumTitle: album['title'] as String? ?? '',
      status: switch ((json['status'] as String?)?.toUpperCase()) {
        'RUNNING' => ScannerJobStatus.running,
        'QUEUED' => ScannerJobStatus.queued,
        _ => ScannerJobStatus.unknown,
      },
    );
  }
}

/// The server-side user preferences the app reads.
///
/// [language] is carried even though the app never shows it: the mutation that
/// writes preferences replaces the whole record, so anything not sent back is
/// erased. Holding it here is what lets a write preserve it.
class UserPreferences {
  final String? language;

  /// Null when unset, in which case the app falls back to its own default.
  /// Zero means unlimited.
  final int? searchResultLimit;

  /// Whether the web interface shows its album tree sidebar.
  ///
  /// The app never acts on this — it is a statement about a browser window.
  /// It is read and written back for the same reason as [language]: so that
  /// saving the search limit here does not silently switch it off over there.
  /// Null both when the server has no such field and when it is simply unset;
  /// the two are told apart by [Capability.albumTreePreference], not here.
  final bool? showAlbumTree;

  const UserPreferences({
    this.language,
    this.searchResultLimit,
    this.showAlbumTree,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        language: json['language'] as String?,
        searchResultLimit: json['searchResultLimit'] as int?,
        showAlbumTree: json['showAlbumTree'] as bool?,
      );
}

class SearchResults {
  final String query;
  final List<AlbumItem> albums;
  final List<MediaItem> media;

  const SearchResults({
    required this.query,
    this.albums = const [],
    this.media = const [],
  });

  factory SearchResults.fromJson(Map<String, dynamic> json) => SearchResults(
    query: json['query'] as String? ?? '',
    albums: (json['albums'] as List<dynamic>? ?? const [])
        .map((e) => AlbumItem.fromJson(e as Map<String, dynamic>))
        .toList(),
    media: (json['media'] as List<dynamic>? ?? const [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// One geotagged photo pin, decoded from the server's GeoJSON FeatureCollection.
class PlacesMarker {
  final String mediaId;
  final String mediaTitle;
  final Thumbnail thumbnail;
  final double latitude;
  final double longitude;

  const PlacesMarker({
    required this.mediaId,
    required this.mediaTitle,
    required this.thumbnail,
    required this.latitude,
    required this.longitude,
  });

  static PlacesMarker? fromFeature(Map<String, dynamic> feature) {
    final props = feature['properties'] as Map<String, dynamic>?;
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    if (props == null || geometry == null) return null;
    if (geometry['type'] != 'Point') return null;

    final coords = geometry['coordinates'] as List<dynamic>?;
    if (coords == null || coords.length < 2) return null;

    final thumb = props['thumbnail'] as Map<String, dynamic>?;
    if (thumb == null) return null;

    return PlacesMarker(
      mediaId: props['media_id'].toString(),
      mediaTitle: props['media_title'] as String? ?? '',
      thumbnail: Thumbnail.fromJson(thumb),
      // GeoJSON orders coordinates as [longitude, latitude].
      longitude: (coords[0] as num).toDouble(),
      latitude: (coords[1] as num).toDouble(),
    );
  }
}
