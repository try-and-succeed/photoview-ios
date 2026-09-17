import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/state/search_limit.dart' show settingsStoreProvider;
import 'package:photoview/state/slideshow.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// Pages without a thumbnail draw a placeholder and ask for nothing over the
/// network, while still being pages the slideshow turns.
List<MediaItem> _photos(int count) => [
  for (var i = 0; i < count; i++) MediaItem(id: '$i', type: MediaType.photo),
];

MediaDetails _detailsFor(String id) => MediaDetails(
  media: MediaItem(id: id, type: MediaType.photo),
  title: 'photo-$id.jpg',
);

/// Records what the gallery asked of the screen, without a platform channel.
class _Screen {
  final asked = <bool>[];

  Future<void> call(bool awake) async => asked.add(awake);
}

/// Settings kept in memory: the real store talks to secure storage, which no
/// test binding answers.
class _MemorySettings extends SettingsStore {
  int? seconds;

  @override
  Future<int?> slideshowSeconds() async => seconds;

  @override
  Future<void> setSlideshowSeconds(int? value) async => seconds = value;
}

Future<_Screen> _openGallery(
  WidgetTester tester, {
  required List<MediaItem> media,
  SettingsStore? settings,
}) async {
  final screen = _Screen();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        mediaDetailsProvider.overrideWith((ref, id) async => _detailsFor(id)),
        screenAwakeProvider.overrideWithValue(screen.call),
        if (settings != null) settingsStoreProvider.overrideWithValue(settings),
      ],
      child: localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenGallery(
              context,
              media: media,
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
  return screen;
}

/// The running app's container, for changing a setting the way the settings
/// screen would while the gallery is open.
ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(FullscreenGallery)));

/// One slideshow interval, plus the page turn it starts.
Future<void> _waitOneSlide(
  WidgetTester tester, {
  int seconds = defaultSlideshowSeconds,
}) async {
  await tester.pump(Duration(seconds: seconds));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the slideshow turns the pages by itself', (tester) async {
    await _openGallery(tester, media: _photos(3));
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await _waitOneSlide(tester);
    expect(find.text('2 / 3'), findsOneWidget);

    await _waitOneSlide(tester);
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('it starts over at the end rather than stopping', (tester) async {
    await _openGallery(tester, media: _photos(2));

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await _waitOneSlide(tester);
    expect(find.text('2 / 2'), findsOneWidget);

    await _waitOneSlide(tester);
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('stopping it leaves the page where it is', (tester) async {
    await _openGallery(tester, media: _photos(3));

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();
    await _waitOneSlide(tester);

    // The controls fade out when the slideshow starts; a tap on the photo
    // brings them back.
    await tester.tap(find.byIcon(Icons.broken_image_outlined).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Stop slideshow'));
    await tester.pumpAndSettle();

    await _waitOneSlide(tester);
    await _waitOneSlide(tester);
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('the screen is held awake only while it runs', (tester) async {
    final screen = await _openGallery(tester, media: _photos(3));
    expect(screen.asked, isEmpty);

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();
    expect(screen.asked, [true]);

    await tester.tap(find.byIcon(Icons.broken_image_outlined).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop slideshow'));
    await tester.pumpAndSettle();

    expect(screen.asked, [true, false]);
  });

  testWidgets('leaving the gallery hands the screen back', (tester) async {
    // Closing a running slideshow must not leave the device unable to sleep.
    final screen = await _openGallery(tester, media: _photos(3));

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.broken_image_outlined).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(screen.asked, [true, false]);
  });

  testWidgets('videos are stepped over, not cut off after five seconds', (
    tester,
  ) async {
    await _openGallery(
      tester,
      media: const [
        MediaItem(id: '0', type: MediaType.photo),
        MediaItem(id: '1', type: MediaType.video),
        MediaItem(id: '2', type: MediaType.photo),
      ],
    );

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await _waitOneSlide(tester);
    expect(find.text('3 / 3'), findsOneWidget, reason: 'the video was skipped');
  });

  testWidgets('it rests for as long as the setting says', (tester) async {
    await _openGallery(
      tester,
      media: _photos(3),
      settings: _MemorySettings()..seconds = 10,
    );

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await _waitOneSlide(tester);
    expect(find.text('1 / 3'), findsOneWidget, reason: 'five seconds is not ten');

    await _waitOneSlide(tester);
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('changing the setting is felt on the next picture', (
    tester,
  ) async {
    // A periodic timer would have held the old interval until the slideshow
    // was stopped and started again.
    final settings = _MemorySettings()..seconds = 30;
    await _openGallery(tester, media: _photos(3), settings: settings);

    await tester.tap(find.byTooltip('Start slideshow'));
    await tester.pumpAndSettle();

    await _containerOf(tester).read(slideshowSecondsProvider.notifier).choose(3);
    await tester.pumpAndSettle();

    await _waitOneSlide(tester, seconds: 3);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(settings.seconds, 3, reason: 'and it is kept for the next start');
  });

  test('the chosen interval outlives the session', () async {
    final settings = _MemorySettings();

    final first = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(settings)],
    );
    addTearDown(first.dispose);

    expect(
      await first.read(slideshowSecondsProvider.future),
      defaultSlideshowSeconds,
      reason: 'nothing chosen yet',
    );

    await first.read(slideshowSecondsProvider.notifier).choose(15);
    expect(settings.seconds, 15);

    final afterRestart = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(settings)],
    );
    addTearDown(afterRestart.dispose);

    expect(await afterRestart.read(slideshowSecondsProvider.future), 15);
  });

  testWidgets('a gallery of nothing but videos offers no slideshow', (
    tester,
  ) async {
    await _openGallery(
      tester,
      media: const [MediaItem(id: '0', type: MediaType.video)],
    );

    expect(find.byTooltip('Start slideshow'), findsNothing);
  });
}
