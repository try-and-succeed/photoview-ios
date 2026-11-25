import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/state/media_layout.dart';
import 'package:photoview/state/search_limit.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';
import 'package:photoview/widgets/media_grid.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// Keeps the layout in memory: the real store's secure storage has no
/// platform side in a test.
class _MemorySettings extends SettingsStore {
  _MemorySettings([this.layout]);

  String? layout;

  @override
  Future<String?> mediaLayout() async => layout;

  @override
  Future<void> setMediaLayout(String? value) async => layout = value;
}

const _longName = 'Scan_2024-03-17_Steuerbescheid_Seite_01_von_12.jpg';

final _media = [
  const MediaItem(id: '0', type: MediaType.photo, title: _longName),
  const MediaItem(id: '1', type: MediaType.video, title: 'clip.mp4'),
  const MediaItem(id: '2', type: MediaType.photo),
];

Future<void> _pump(
  WidgetTester tester,
  _MemorySettings settings, {
  MediaSelection? selection,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        settingsStoreProvider.overrideWithValue(settings),
        mediaDetailsProvider.overrideWith(
          (ref, id) async => MediaDetails(
            media: _media[int.parse(id)],
            title: _media[int.parse(id)].title,
          ),
        ),
      ],
      child: localizedApp(
        home: Scaffold(
          appBar: AppBar(actions: const [MediaLayoutButton()]),
          body: CustomScrollView(
            slivers: [MediaSliverGrid(media: _media, selection: selection)],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('file names may break after their separators only', () {
    expect(breakableFileName('IMG_2024-03.jpg'), 'IMG_​2024-​03.​jpg');
    expect(breakableFileName('Urlaub'), 'Urlaub');
  });

  test('the layout is tiles until a list is chosen, and stays chosen', () async {
    final settings = _MemorySettings();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(settings)],
    );
    addTearDown(container.dispose);

    expect(await container.read(mediaLayoutProvider.future), MediaLayout.grid);

    await container.read(mediaLayoutProvider.notifier).choose(MediaLayout.list);
    expect(settings.layout, 'list');

    // A fresh start reads the stored choice back.
    final again = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(settings)],
    );
    addTearDown(again.dispose);
    expect(await again.read(mediaLayoutProvider.future), MediaLayout.list);
  });

  test('an unknown stored layout counts as tiles', () async {
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(_MemorySettings('mosaic')),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(mediaLayoutProvider.future), MediaLayout.grid);
  });

  testWidgets('the button switches tiles to whole file names and back', (
    tester,
  ) async {
    final settings = _MemorySettings();
    await _pump(tester, settings);

    expect(find.byType(MediaThumbnail), findsNWidgets(3));
    expect(find.byType(MediaListRow), findsNothing);

    await tester.tap(find.byTooltip('Show as list'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaThumbnail), findsNothing);
    expect(find.byType(MediaListRow), findsNWidgets(3));
    // The whole name, not cut off, and a placeholder where there is none.
    expect(find.text(breakableFileName(_longName)), findsOneWidget);
    final text = tester.widget<Text>(find.text(breakableFileName(_longName)));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
    expect(find.text('Untitled'), findsOneWidget);
    expect(settings.layout, 'list');

    await tester.tap(find.byTooltip('Show as tiles'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaThumbnail), findsNWidgets(3));
    expect(settings.layout, 'grid');
  });

  testWidgets('a long name wraps instead of being cut off', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, _MemorySettings('list'));

    final long = tester.getSize(find.text(breakableFileName(_longName)));
    final short = tester.getSize(find.text(breakableFileName('clip.mp4')));
    expect(long.height, greaterThan(short.height));
  });

  testWidgets('a tap on a row opens the photo', (tester) async {
    await _pump(tester, _MemorySettings('list'));

    await tester.tap(find.byType(MediaListRow).first);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenGallery), findsOneWidget);
  });

  testWidgets('rows are picked like tiles', (tester) async {
    final selected = <String>{};
    late StateSetter rebuild;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(_session),
          settingsStoreProvider.overrideWithValue(_MemorySettings('list')),
        ],
        child: localizedApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return CustomScrollView(
                  slivers: [
                    MediaSliverGrid(
                      media: _media,
                      selection: MediaSelection(
                        selected: selected,
                        onToggle: (item) => rebuild(() {
                          if (!selected.remove(item.id)) selected.add(item.id);
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(MediaListRow).first);
    await tester.pumpAndSettle();
    expect(selected, {'0'});
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.circle_outlined), findsNWidgets(2));

    // While picking, a tap ticks rather than opening the photo.
    await tester.tap(find.byType(MediaListRow).at(1));
    await tester.pumpAndSettle();
    expect(selected, {'0', '1'});
    expect(find.byType(FullscreenGallery), findsNothing);
  });
}
