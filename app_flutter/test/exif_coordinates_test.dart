import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/l10n/app_localizations.dart';
import 'package:photoview/util/formatting.dart';
import 'package:photoview/widgets/exif_table.dart';

import 'support/localized_app.dart';

const _berlin = MediaCoordinates(latitude: 52.520008, longitude: 13.404954);

void main() {
  group('MediaCoordinates.fromJson', () {
    test('reads a position the server sent', () {
      final position = MediaCoordinates.fromJson({
        'latitude': 40.7061,
        'longitude': -73.9969,
      });

      expect(position?.latitude, 40.7061);
      expect(position?.longitude, -73.9969);
    });

    test('half a position is no position', () {
      expect(MediaCoordinates.fromJson(null), isNull);
      expect(MediaCoordinates.fromJson({}), isNull);
      expect(MediaCoordinates.fromJson({'latitude': 52.5}), isNull);
      expect(MediaCoordinates.fromJson({'longitude': 13.4}), isNull);
    });

    test('takes whole numbers as the server writes them', () {
      // On the equator or the prime meridian the server sends an int.
      final position = MediaCoordinates.fromJson({
        'latitude': 0,
        'longitude': 13,
      });

      expect(position?.latitude, 0);
      expect(position?.longitude, 13);
    });
  });

  group('formatCoordinates', () {
    test('writes decimal degrees a map can be given', () {
      expect(formatCoordinates(_berlin), '52.520008, 13.404954');
    });

    test('keeps the sign rather than a letter', () {
      // N/S/E/W differ by language, and a pasted position must not.
      expect(
        formatCoordinates(
          const MediaCoordinates(latitude: -33.8688, longitude: 151.2093),
        ),
        '-33.8688, 151.2093',
      );
    });

    test('does not imply precision that is not there', () {
      expect(
        formatCoordinates(
          const MediaCoordinates(latitude: 52.5, longitude: 13),
        ),
        '52.5, 13',
      );
    });

    test('stays machine-readable in a language with a decimal comma', () {
      // The one value on the sheet worth carrying elsewhere: every map takes
      // "52.520008, 13.404954", none take a decimal comma.
      Intl.defaultLocale = 'de';
      addTearDown(() => Intl.defaultLocale = null);

      expect(formatCoordinates(_berlin), '52.520008, 13.404954');
    });
  });

  testWidgets('the details show where the photo was taken', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(
          body: ExifTable(
            exif: MediaExif(camera: 'ILCE-7M4', coordinates: _berlin),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GPS position'), findsOneWidget);
    expect(find.text('52.520008, 13.404954'), findsOneWidget);
  });

  testWidgets('a photo without a position says nothing about one', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(body: ExifTable(exif: MediaExif(iso: 400))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GPS position'), findsNothing);
  });

  test('the row sits with the rest of the camera data', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final rows = exifRows(
      const MediaExif(camera: 'ILCE-7M4', iso: 100, coordinates: _berlin),
      l10n,
    );

    expect(rows.map((r) => r.label), contains('GPS position'));
    expect(
      rows.last.label,
      'GPS position',
      reason: 'after the camera settings, not among them',
    );
  });
}
