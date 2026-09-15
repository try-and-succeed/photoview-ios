import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';

void main() {
  group('PhotoviewClient.candidateBases', () {
    List<String> bases(String input) =>
        PhotoviewClient.candidateBases(input).map((u) => u.toString()).toList();

    test('tries a bare host over HTTPS only, never plain HTTP', () {
      expect(bases('photoview.lan'), ['https://photoview.lan/']);
    });

    test('keeps a port on a bare host', () {
      expect(bases('192.168.0.47:8080'), ['https://192.168.0.47:8080/']);
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

  group('Session.cacheKeyFor', () {
    Session sessionFor(String endpoint, String username, String token) =>
        Session(
          endpoint: Uri.parse(endpoint),
          username: username,
          token: token,
        );

    test('separates two accounts on the same instance', () {
      final alice = sessionFor('https://example.com/api/graphql', 'alice', 'a');
      final bob = sessionFor('https://example.com/api/graphql', 'bob', 'b');

      expect(
        alice.cacheKeyFor('photo/thumbnail_x.jpg'),
        isNot(bob.cacheKeyFor('photo/thumbnail_x.jpg')),
      );
    });

    test('separates two instances that differ only by port', () {
      final first = sessionFor('http://host:8080/api/graphql', 'admin', 't');
      final second = sessionFor('http://host:8081/api/graphql', 'admin', 't');

      expect(
        first.cacheKeyFor('photo/thumbnail_x.jpg'),
        isNot(second.cacheKeyFor('photo/thumbnail_x.jpg')),
      );
    });

    test('survives a new token for the same account', () {
      // A fresh sign-in issues a new token. Keying on it would throw away
      // every cached thumbnail each time the session is renewed.
      final before = sessionFor('https://example.com/api/graphql', 'admin', '1');
      final after = sessionFor('https://example.com/api/graphql', 'admin', '2');

      expect(
        before.cacheKeyFor('photo/thumbnail_x.jpg'),
        after.cacheKeyFor('photo/thumbnail_x.jpg'),
      );
    });

    test('never contains the token', () {
      final session = sessionFor(
        'https://example.com/api/graphql',
        'admin',
        'super-secret-token',
      );

      // Cache keys become file names on disk, so the token must not be one.
      expect(
        session.cacheKeyFor('photo/thumbnail_x.jpg'),
        isNot(contains('super-secret-token')),
      );
    });

    test('distinguishes two media paths', () {
      final session = sessionFor('https://example.com/api/graphql', 'admin', 't');

      expect(
        session.cacheKeyFor('photo/a.jpg'),
        isNot(session.cacheKeyFor('photo/b.jpg')),
      );
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

    test('reads the full rendition when the server names one', () {
      final details = MediaDetails.fromJson({
        'id': '1',
        'type': 'Photo',
        'title': 'screenshots_02.jpg',
        'highRes': {
          'url': '/api/photo/screenshots_02_4jrdROju.jpg',
          'width': 1920,
          'height': 1080,
        },
      });

      expect(details.highRes?.url, '/api/photo/screenshots_02_4jrdROju.jpg');
      expect(details.highRes?.width, 1920);
    });

    test('has no full rendition when the server sends none', () {
      // Videos come back with highRes null.
      for (final highRes in [null, <String, dynamic>{'url': null}]) {
        final details = MediaDetails.fromJson({
          'id': '7',
          'type': 'Video',
          'highRes': highRes,
        });
        expect(details.highRes, isNull, reason: 'highRes: $highRes');
      }
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

  group('MediaItem.copyWith', () {
    test('keeps every field it is not asked to change', () {
      const original = MediaItem(
        id: '7',
        type: MediaType.video,
        title: 'IMG_0001.mov',
        blurhash: 'LEHV6nWB2yk8',
        thumbnail: Thumbnail(url: 'a.jpg', width: 4, height: 3),
      );

      final copy = original.copyWith(favorite: true);

      expect(copy.id, original.id);
      expect(copy.type, original.type);
      expect(copy.title, original.title);
      expect(copy.blurhash, original.blurhash);
      expect(copy.thumbnail, same(original.thumbnail));
      expect(copy.favorite, isTrue);
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
