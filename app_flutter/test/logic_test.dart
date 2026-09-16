import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/l10n/app_localizations.dart';
import 'package:photoview/screens/places_screen.dart';
import 'package:photoview/state/timeline.dart';
import 'package:photoview/util/formatting.dart';

TimelineMedia _entry(String id, String albumId, DateTime date) => TimelineMedia(
  media: MediaItem(id: id, type: MediaType.photo),
  date: date,
  albumId: albumId,
  albumTitle: 'Album $albumId',
);

final _en = lookupAppLocalizations(const Locale('en'));
final _de = lookupAppLocalizations(const Locale('de'));

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

    test('uses the decimal separator of the app language', () {
      Intl.withLocale('de', () {
        expect(formatBytes(2500), '2,5 kB');
        expect(formatBytes(9000000), '9,0 MB');
      });
    });

    test('names the server renditions in the app language', () {
      expect(renditionName('Original', _en), 'Original');
      expect(renditionName('Large', _de), 'Groß');
      expect(renditionName('Small', _de), 'Klein');
      expect(renditionName('Web optimized video', _de), 'Fürs Web optimiertes Video');
      // A title the app does not know yet is shown as the server sent it.
      expect(renditionName('Panorama', _de), 'Panorama');
    });

    test('extracts the file extension from a media URL', () {
      expect(fileExtension('photo/original_abc.JPG'), 'jpg');
      expect(fileExtension('photo/noext'), '');
    });
  });

  group('safeFileName', () {
    test('keeps an ordinary file name', () {
      expect(
        safeFileName(Uri.parse('http://host/api/photo/berge_01.jpg')),
        'berge_01.jpg',
      );
    });

    test('strips a separator smuggled in as an escape', () {
      // pathSegments decodes %2F, so the last segment would otherwise carry a
      // separator and escape the directory it is joined onto.
      expect(
        safeFileName(Uri.parse('http://host/api/photo/..%2F..%2Fevil.sh')),
        'evil.sh',
      );
      expect(
        safeFileName(Uri.parse('http://host/api/photo/a%5Cb%5Cc.jpg')),
        'c.jpg',
      );
    });

    test('falls back for names that address a directory', () {
      expect(safeFileName(Uri.parse('http://host/api/photo/')), 'download');
      expect(safeFileName(Uri.parse('http://host')), 'download');
      expect(safeFileName(Uri.parse('http://host/api/photo/%2E%2E')), 'download');
    });

    test('names known exposure programs', () {
      expect(exposureProgramName(3, _en), 'Aperture priority');
      expect(exposureProgramName(99, _en), 'Unknown');
      expect(exposureProgramName(4, _de), 'Zeitpriorität');
    });

    test('lists EXIF rows in display order, skipping absent fields', () {
      final rows = exifRows(
        const MediaExif(camera: 'X-T5', iso: 400, aperture: 2.8),
        _en,
      );

      expect(rows.map((r) => r.label), ['Camera', 'Aperture', 'ISO']);
      expect(rows.map((r) => r.value), ['X-T5', 'f/2.8', '400']);
    });

    test('labels EXIF rows and numbers in the app language', () {
      final rows = Intl.withLocale(
        'de',
        () => exifRows(const MediaExif(aperture: 2.8, focalLength: 4.5), _de),
      );

      expect(rows.map((r) => r.label), ['Blende', 'Brennweite']);
      expect(rows.map((r) => r.value), ['f/2,8', '4,5 mm']);
    });
  });
}
