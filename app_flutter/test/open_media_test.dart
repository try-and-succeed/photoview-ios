import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';
import 'package:photoview/widgets/media_details_sheet.dart';
import 'package:photoview/widgets/media_grid.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// Without a thumbnail a tile draws a placeholder and asks for nothing over the
/// network, while still being the same tile with the same tap handling.
final _media = [
  for (var i = 0; i < 3; i++) MediaItem(id: '$i', type: MediaType.photo),
];

MediaDetails _detailsFor(String id, {bool exif = true}) => MediaDetails(
  media: MediaItem(id: id, type: MediaType.photo),
  title: 'photo-$id.jpg',
  exif: exif ? MediaExif(camera: 'Camera $id', iso: 400) : null,
  downloads: const [
    MediaDownload(
      title: 'Original',
      url: '/api/photo/a.jpg',
      width: 4000,
      height: 3000,
      fileSize: 4200000,
    ),
  ],
);

Future<void> _pumpGrid(WidgetTester tester, {bool exif = true}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        mediaDetailsProvider.overrideWith(
          (ref, id) async => _detailsFor(id, exif: exif),
        ),
      ],
      child: localizedApp(
        home: Scaffold(body: MediaGrid(media: _media)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a tap on a photo shows the photo, not its data', (tester) async {
    // The details are wanted far less often than the picture, and they used to
    // be what a tap produced.
    await _pumpGrid(tester);

    await tester.tap(find.byType(MediaThumbnail).first);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenGallery), findsOneWidget);
    expect(find.byType(MediaDetailsSheet), findsNothing);
  });

  testWidgets('the info button carries the downloads and links too', (
    tester,
  ) async {
    // The gallery's own panel had only the camera data. Moving the tap to the
    // gallery would otherwise have put downloads and public links out of reach
    // from an album.
    await _pumpGrid(tester);

    await tester.tap(find.byType(MediaThumbnail).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Info'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaDetailsSheet), findsOneWidget);
    expect(find.text('Camera 0'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    // Section headers are set in capitals.
    expect(find.text('SHARE LINKS'), findsOneWidget);
  });

  testWidgets('the info sheet leaves the photo showing behind it', (
    tester,
  ) async {
    // Opened from the gallery the sheet heads with no preview: the picture is
    // already on screen, and a preview that reopens the gallery would stack a
    // second one on the first.
    await _pumpGrid(tester);

    await tester.tap(find.byType(MediaThumbnail).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Info'));
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenGallery), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('a photo without camera data says so', (tester) async {
    await _pumpGrid(tester, exif: false);

    await tester.tap(find.byType(MediaThumbnail).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Info'));
    await tester.pumpAndSettle();

    expect(find.text('No camera data for this photo.'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
  });
}
