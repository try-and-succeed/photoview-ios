import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/screens/places_screen.dart';
import 'package:photoview/state/timeline.dart';
import 'package:photoview/util/formatting.dart';

TimelineMedia _entry(String id, String albumId, DateTime date) => TimelineMedia(
  media: MediaItem(id: id, type: MediaType.photo),
  date: date,
  albumId: albumId,
  albumTitle: 'Album $albumId',
);

PlacesMarker _marker(double lat, double lng) => PlacesMarker(
  mediaId: '$lat:$lng',
  mediaTitle: '',
  thumbnail: const Thumbnail(url: 'a.jpg'),
  latitude: lat,
  longitude: lng,
);

void main() {
  group('groupTimeline', () {
    test('groups consecutive media from the same album and day', () {
      final groups = groupTimeline([
        _entry('1', 'a', DateTime(2024, 5, 1, 9)),
        _entry('2', 'a', DateTime(2024, 5, 1, 17)),
        _entry('3', 'a', DateTime(2024, 5, 1, 22)),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.media.map((m) => m.id), ['1', '2', '3']);
    });

    test('starts a new group when the day changes', () {
      final groups = groupTimeline([
        _entry('1', 'a', DateTime(2024, 5, 1, 23)),
        _entry('2', 'a', DateTime(2024, 5, 2, 1)),
      ]);

      expect(groups, hasLength(2));
    });

    test('starts a new group when the album changes', () {
      final groups = groupTimeline([
        _entry('1', 'a', DateTime(2024, 5, 1, 9)),
        _entry('2', 'b', DateTime(2024, 5, 1, 10)),
      ]);

      expect(groups, hasLength(2));
      expect(groups[1].albumId, 'b');
    });

    test('reuses an album that reappears later as a separate group', () {
      final groups = groupTimeline([
        _entry('1', 'a', DateTime(2024, 5, 1, 9)),
        _entry('2', 'b', DateTime(2024, 5, 1, 10)),
        _entry('3', 'a', DateTime(2024, 5, 1, 11)),
      ]);

      expect(groups.map((g) => g.albumId), ['a', 'b', 'a']);
    });

    test('returns nothing for an empty timeline', () {
      expect(groupTimeline([]), isEmpty);
    });
  });

  group('clusterMarkers', () {
    test('merges nearby pins when zoomed out', () {
      final clusters = clusterMarkers([
        _marker(55.6761, 12.5683),
        _marker(55.6765, 12.5690),
      ], 3);

      expect(clusters, hasLength(1));
      expect(clusters.single.isSingle, isFalse);
      expect(clusters.single.markers, hasLength(2));
    });

    test('separates the same pins when zoomed in', () {
      final clusters = clusterMarkers([
        _marker(55.0, 12.0),
        _marker(56.0, 13.0),
      ], 18);

      expect(clusters, hasLength(2));
      expect(clusters.every((c) => c.isSingle), isTrue);
    });

    test('centres a cluster on its members', () {
      final clusters = clusterMarkers([
        _marker(10.0, 20.0),
        _marker(10.2, 20.2),
      ], 2);

      expect(clusters, hasLength(1));
      expect(clusters.single.center.latitude, closeTo(10.1, 0.0001));
      expect(clusters.single.center.longitude, closeTo(20.1, 0.0001));
    });
  });

  group('formatting', () {
    test('renders fast shutter speeds as a fraction', () {
      expect(formatExposure(0.008), '1/125');
      expect(formatExposure(0.5), '1/2');
    });

    test('renders long exposures in seconds', () {
      expect(formatExposure(2), '2 s');
    });

    test('scales byte counts', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2500), '2.5 kB');
      expect(formatBytes(9000000), '9.0 MB');
    });

    test('extracts the file extension from a media URL', () {
      expect(fileExtension('photo/original_abc.JPG'), 'jpg');
      expect(fileExtension('photo/noext'), '');
    });

    test('names known exposure programs', () {
      expect(exposureProgramName(3), 'Aperture priority');
      expect(exposureProgramName(99), 'Unknown');
    });

    test('lists EXIF rows in display order, skipping absent fields', () {
      final rows = exifRows(
        const MediaExif(camera: 'X-T5', iso: 400, aperture: 2.8),
      );

      expect(rows.map((r) => r.label), ['Camera', 'Aperture', 'ISO']);
      expect(rows.map((r) => r.value), ['X-T5', 'f/2.8', '400']);
    });
  });
}
