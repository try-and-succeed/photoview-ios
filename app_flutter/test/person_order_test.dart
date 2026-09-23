import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';

/// A face group as the server sends it: the faces in detection order, which
/// has nothing to do with when the photos were taken.
const _serverJson = '''
{
  "id": "3",
  "label": null,
  "imageFaces": [
    {"id": "10", "media": {"id": "1", "title": "middle.jpg", "date": "2026-09-05T09:00:00Z"}},
    {"id": "11", "media": {"id": "2", "title": "oldest.jpg", "date": "2024-01-31T18:30:00Z"}},
    {"id": "12", "media": {"id": "3", "title": "newest.jpg", "date": "2026-09-16T20:51:27Z"}}
  ]
}
''';

Map<String, dynamic> _group(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  test('a person\'s photos come back newest first', () {
    final photos = personPhotosFrom(_group(_serverJson));

    expect(
      photos.map((p) => p.media.title),
      ['newest.jpg', 'middle.jpg', 'oldest.jpg'],
    );
  });

  test('a photo the server did not date goes last, not missing', () {
    final photos = personPhotosFrom(
      _group('''
      {
        "imageFaces": [
          {"id": "1", "media": {"id": "1", "title": "undated.jpg"}},
          {"id": "2", "media": {"id": "2", "title": "dated.jpg", "date": "2026-09-16T20:51:27Z"}}
        ]
      }
      '''),
    );

    expect(photos.map((p) => p.media.title), ['dated.jpg', 'undated.jpg']);
  });

  test('a date the server sent in a shape we cannot read is not fatal', () {
    final photos = personPhotosFrom(
      _group('''
      {
        "imageFaces": [
          {"id": "1", "media": {"id": "1", "title": "odd.jpg", "date": "not a date"}},
          {"id": "2", "media": {"id": "2", "title": "fine.jpg", "date": "2026-09-16T20:51:27Z"}}
        ]
      }
      '''),
    );

    expect(photos.map((p) => p.media.title), ['fine.jpg', 'odd.jpg']);
  });

  test('offsets are compared as instants, not as written', () {
    // 2026-09-16T23:30+02:00 is earlier than 2026-09-16T22:00Z.
    final photos = personPhotosFrom(
      _group('''
      {
        "imageFaces": [
          {"id": "1", "media": {"id": "1", "title": "berlin.jpg", "date": "2026-09-16T23:30:00+02:00"}},
          {"id": "2", "media": {"id": "2", "title": "utc.jpg", "date": "2026-09-16T22:00:00Z"}}
        ]
      }
      '''),
    );

    expect(photos.map((p) => p.media.title), ['utc.jpg', 'berlin.jpg']);
  });

  test('a face group with nothing in it is empty, not an error', () {
    expect(personPhotosFrom(null), isEmpty);
    expect(personPhotosFrom(_group('{"id": "3"}')), isEmpty);
  });

  test('the face ids come back with the photos', () {
    // They are what `moveImageFaces` and `detachImageFaces` take; the media
    // ids are no use to either.
    final photos = personPhotosFrom(_group(_serverJson));

    expect(photos.map((p) => p.faceIds), [
      ['12'],
      ['10'],
      ['11'],
    ]);
  });

  test('a photo this person is in twice is one tile with both faces', () {
    // The detector can find the same person twice in one picture. Two tiles
    // would claim more photos than there are, and ticking one of them would
    // file half a photo under somebody else.
    final photos = personPhotosFrom(
      _group('''
      {
        "imageFaces": [
          {"id": "1", "media": {"id": "9", "title": "both.jpg", "date": "2026-09-16T20:51:27Z"}},
          {"id": "2", "media": {"id": "9", "title": "both.jpg", "date": "2026-09-16T20:51:27Z"}}
        ]
      }
      '''),
    );

    expect(photos.map((p) => p.media.title), ['both.jpg']);
    expect(photos.single.faceIds, ['1', '2']);
  });

  test('a face without an id is left out rather than sent as null', () {
    // Sending null in `imageFaceIDs` is an error at the server, and the whole
    // action would fail over one odd row.
    final photos = personPhotosFrom(
      _group('''
      {
        "imageFaces": [
          {"media": {"id": "9", "title": "nameless.jpg"}},
          {"id": "2", "media": {"id": "9", "title": "nameless.jpg"}}
        ]
      }
      '''),
    );

    expect(photos.single.faceIds, ['2']);
  });
}
