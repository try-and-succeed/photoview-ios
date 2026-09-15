import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// Pages without a thumbnail render a placeholder icon — no network needed,
/// but still photo pages with the same tap handling.
final _offlinePages = [
  for (var i = 0; i < 3; i++) MediaItem(id: '$i', type: MediaType.photo),
];

/// Details as the server would send them, with camera data unless [exif] is
/// false.
MediaDetails _detailsFor(String id, {bool exif = true}) => MediaDetails(
  media: MediaItem(id: id, type: MediaType.photo),
  title: 'photo-$id.jpg',
  exif: exif ? MediaExif(camera: 'Camera $id', iso: 400) : null,
);

/// Opens the gallery from a home screen, so closing it has somewhere to go.
Future<void> _openGallery(WidgetTester tester, {bool exif = true}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        mediaDetailsProvider.overrideWith(
          (ref, id) async => _detailsFor(id, exif: exif),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenGallery(
              context,
              media: _offlinePages,
              initialIndex: 0,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _controlsOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.byType(AppBar), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

/// A single tap, given time to be told apart from the first half of a double
/// tap, which zooms.
Future<void> _tapPhoto(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.broken_image_outlined));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

const _thumbnail = Thumbnail(url: '/api/photo/thumbnail_a.jpg', width: 1024, height: 576);
const _full = Thumbnail(url: '/api/photo/a.jpg', width: 1920, height: 1080);

const _item = MediaItem(id: '4', type: MediaType.photo, thumbnail: _thumbnail);

MediaDetails _details({Thumbnail? highRes}) =>
    MediaDetails(media: _item, title: 'a.jpg', highRes: highRes);

void main() {
  group('galleryLayers', () {
    test('shows the thumbnail while the details are still loading', () {
      expect(galleryLayers(_item, null), [_thumbnail]);
    });

    test('layers the full image over the thumbnail once it is known', () {
      // The point of this stage: the gallery used to show only the thumbnail,
      // at most 1024 px, even full screen and zoomed in.
      expect(galleryLayers(_item, _details(highRes: _full)), [_thumbnail, _full]);
    });

    test('adds nothing when the server names no full image', () {
      expect(galleryLayers(_item, _details()), [_thumbnail]);
    });

    test('does not load the same file twice as two layers', () {
      expect(galleryLayers(_item, _details(highRes: _thumbnail)), [_thumbnail]);
    });
  });

  group('galleryActionFor', () {
    test('arrows and page keys turn pages, Escape closes', () {
      expect(galleryActionFor(LogicalKeyboardKey.arrowLeft), GalleryAction.previous);
      expect(galleryActionFor(LogicalKeyboardKey.pageUp), GalleryAction.previous);
      expect(galleryActionFor(LogicalKeyboardKey.arrowRight), GalleryAction.next);
      expect(galleryActionFor(LogicalKeyboardKey.pageDown), GalleryAction.next);
      expect(galleryActionFor(LogicalKeyboardKey.escape), GalleryAction.close);
      expect(galleryActionFor(LogicalKeyboardKey.keyI), GalleryAction.info);
    });

    test('leaves every other key alone', () {
      expect(galleryActionFor(LogicalKeyboardKey.tab), isNull);
      expect(galleryActionFor(LogicalKeyboardKey.keyA), isNull);
    });
  });

  group('FullscreenGallery presentation', () {
    testWidgets('a tap on the photo hides the controls, another shows them', (
      tester,
    ) async {
      await _openGallery(tester);
      expect(_controlsOpacity(tester), 1);

      await _tapPhoto(tester);
      expect(_controlsOpacity(tester), 0);

      await _tapPhoto(tester);
      expect(_controlsOpacity(tester), 1);
    });

    testWidgets('hidden controls stay reachable by keyboard', (tester) async {
      // Web had them only on hover, which a keyboard never produces. Here they
      // are faded, not removed, and a key such as Tab brings them back.
      await _openGallery(tester);
      await _tapPhoto(tester);
      expect(_controlsOpacity(tester), 0);
      // The gallery opens as a fullscreen dialog, so its bar has a close
      // button rather than a back button.
      expect(find.byType(CloseButton), findsOneWidget, reason: 'still in the tree');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(_controlsOpacity(tester), 1);
    });

    testWidgets('arrow keys turn the pages', (tester) async {
      await _openGallery(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('the info button shows the camera data of the photo on screen', (
      tester,
    ) async {
      await _openGallery(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Info'));
      await tester.pumpAndSettle();

      // Page two is item "1": the panel follows the page, not the photo the
      // gallery was opened on.
      expect(find.text('photo-1.jpg'), findsOneWidget);
      expect(find.text('Camera 1'), findsOneWidget);
      expect(find.text('Camera 0'), findsNothing);
    });

    testWidgets('the i key opens the same panel', (tester) async {
      await _openGallery(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();

      expect(find.text('Camera 0'), findsOneWidget);
    });

    testWidgets('says so when a photo has no camera data', (tester) async {
      await _openGallery(tester, exif: false);

      await tester.tap(find.byTooltip('Info'));
      await tester.pumpAndSettle();

      expect(find.text('No camera data for this photo.'), findsOneWidget);
    });

    testWidgets('Escape closes the gallery', (tester) async {
      await _openGallery(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });

  test('decodes full images no larger than twice a phone screen and then some',
      () {
    // An original can be tens of megapixels; the gallery keeps neighbouring
    // pages alive. The limit must stay well above screen size for zoom.
    expect(fullImageDecodeLimit, inInclusiveRange(2048, 4096));
  });
}
