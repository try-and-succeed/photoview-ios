import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';

void main() {
  group('PhotoviewClient.candidateBases', () {
    List<String> bases(String input) =>
        PhotoviewClient.candidateBases(input).map((u) => u.toString()).toList();

    test('tries both schemes for a bare host', () {
      expect(bases('photoview.lan'), [
        'https://photoview.lan/',
        'http://photoview.lan/',
      ]);
    });

    test('keeps a port on a bare host', () {
      expect(bases('192.168.0.47:8080'), [
        'https://192.168.0.47:8080/',
        'http://192.168.0.47:8080/',
      ]);
    });

    test('honours an explicit scheme instead of guessing', () {
      expect(bases('http://192.168.0.47:8080'), [
        'http://192.168.0.47:8080/',
      ]);
      expect(bases('https://example.com'), ['https://example.com/']);
    });

    test('appends a trailing slash so sub-paths are preserved', () {
      expect(bases('https://example.com/photos'), [
        'https://example.com/photos/',
      ]);
    });

    test('trims surrounding whitespace', () {
      expect(bases('  https://example.com  '), ['https://example.com/']);
    });

    test('rejects input without a host', () {
      expect(bases(''), isEmpty);
      expect(bases('   '), isEmpty);
      expect(bases('https://'), isEmpty);
    });
  });

  group('Session.resolve', () {
    test('resolves relative media paths against the instance', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/api/graphql'),
        token: 'tok',
      );

      expect(
        session.resolve('photo/thumb_abc.jpg').toString(),
        'https://example.com/api/photo/thumb_abc.jpg',
      );
    });

    test('resolves the root-relative paths the server sends', () {
      // Verified against a live instance: thumbnail URLs arrive as
      // "/api/photo/thumbnail_xyz.jpg".
      final session = Session(
        endpoint: Uri.parse('http://192.168.0.47:8081/api/graphql'),
        token: 'tok',
      );

      expect(
        session.resolve('/api/photo/thumbnail_xyz.jpg').toString(),
        'http://192.168.0.47:8081/api/photo/thumbnail_xyz.jpg',
      );
    });

    test('leaves absolute media URLs untouched', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/api/graphql'),
        token: 'tok',
      );

      expect(
        session.resolve('https://cdn.example.com/a.jpg').toString(),
        'https://cdn.example.com/a.jpg',
      );
    });
  });

  group('Session.shareUrl', () {
    test('strips the api and graphql segments', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/api/graphql'),
        token: 'tok',
      );

      expect(
        session.shareUrl('rMHkKhmX').toString(),
        'https://example.com/share/rMHkKhmX',
      );
    });

    test('handles instances served without the api prefix', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/graphql'),
        token: 'tok',
      );

      expect(
        session.shareUrl('rMHkKhmX').toString(),
        'https://example.com/share/rMHkKhmX',
      );
    });

    test('keeps a sub-path the instance is hosted under', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/photos/api/graphql'),
        token: 'tok',
      );

      expect(
        session.shareUrl('abc').toString(),
        'https://example.com/photos/share/abc',
      );
    });
  });

  group('Session.instanceUrl', () {
    test('recovers the address the user typed', () {
      expect(
        Session(
          endpoint: Uri.parse('http://192.168.0.47:8081/api/graphql'),
          token: 't',
        ).instanceUrl.toString(),
        'http://192.168.0.47:8081',
      );
    });

    test('handles an instance without the api prefix', () {
      expect(
        Session(
          endpoint: Uri.parse('https://example.com/graphql'),
          token: 't',
        ).instanceUrl.toString(),
        'https://example.com',
      );
    });

    test('keeps a sub-path the instance is hosted under', () {
      expect(
        Session(
          endpoint: Uri.parse('https://example.com/photos/api/graphql'),
          token: 't',
        ).instanceUrl.toString(),
        'https://example.com/photos',
      );
    });

    test('feeds back into the sign-in form without doubling graphql', () {
      final session = Session(
        endpoint: Uri.parse('http://host:8081/api/graphql'),
        token: 't',
      );

      // What the welcome screen puts in the Instance field must resolve back
      // to the same endpoint.
      final bases = PhotoviewClient.candidateBases(
        session.instanceUrl.toString(),
      );

      expect(
        bases.map((b) => b.resolve('api/graphql').toString()),
        contains(session.endpoint.toString()),
      );
    });
  });

  group('Session.headers', () {
    test('sends the token as the auth cookie', () {
      final session = Session(
        endpoint: Uri.parse('https://example.com/graphql'),
        token: 'secret',
      );

      expect(session.headers, {'Cookie': 'auth-token=secret'});
    });
  });

  group('PlacesMarker.fromFeature', () {
    test('reads GeoJSON coordinates as [longitude, latitude]', () {
      final marker = PlacesMarker.fromFeature({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [12.5683, 55.6761],
        },
        'properties': {
          'media_id': 42,
          'media_title': 'Copenhagen.jpg',
          'thumbnail': {'url': 'photo/thumb.jpg', 'width': 300, 'height': 200},
        },
      });

      expect(marker, isNotNull);
      expect(marker!.longitude, 12.5683);
      expect(marker.latitude, 55.6761);
      expect(marker.mediaId, '42');
      expect(marker.thumbnail.url, 'photo/thumb.jpg');
    });

    test('rejects features that are not points', () {
      final marker = PlacesMarker.fromFeature({
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [0, 0],
            [1, 1],
          ],
        },
        'properties': {
          'media_id': 1,
          'thumbnail': {'url': 'a.jpg', 'width': 1, 'height': 1},
        },
      });

      expect(marker, isNull);
    });
  });

  group('MediaDetails.fromJson', () {
    test('orders downloads largest first', () {
      final details = MediaDetails.fromJson({
        'id': '1',
        'type': 'PHOTO',
        'title': 'photo.jpg',
        'downloads': [
          {
            'title': 'Thumbnail',
            'mediaUrl': {
              'url': 'a.jpg',
              'width': 100,
              'height': 100,
              'fileSize': 500,
            },
          },
          {
            'title': 'Original',
            'mediaUrl': {
              'url': 'b.jpg',
              'width': 4000,
              'height': 3000,
              'fileSize': 9000000,
            },
          },
          {
            'title': 'High-res',
            'mediaUrl': {
              'url': 'c.jpg',
              'width': 1920,
              'height': 1080,
              'fileSize': 400000,
            },
          },
        ],
      });

      expect(
        details.downloads.map((d) => d.title),
        ['Original', 'High-res', 'Thumbnail'],
      );
    });

    test('maps the video type and web rendition', () {
      final details = MediaDetails.fromJson({
        'id': '7',
        // The server's enum spelling, verified against a live instance.
        'type': 'Video',
        'title': 'clip.mp4',
        'videoWeb': {'url': 'video/clip_web.mp4'},
      });

      expect(details.media.type, MediaType.video);
      expect(details.videoWebUrl, 'video/clip_web.mp4');
    });
  });

  group('MediaItem.fromJson media type', () {
    MediaType typeOf(String? raw) =>
        MediaItem.fromJson({'id': '1', 'type': raw}).type;

    test('reads the spellings the server actually sends', () {
      expect(typeOf('Video'), MediaType.video);
      expect(typeOf('Photo'), MediaType.photo);
    });

    test('tolerates other casings', () {
      expect(typeOf('VIDEO'), MediaType.video);
      expect(typeOf('video'), MediaType.video);
    });

    test('falls back to photo for missing or unknown values', () {
      expect(typeOf(null), MediaType.photo);
      expect(typeOf('Audio'), MediaType.photo);
    });
  });
}
