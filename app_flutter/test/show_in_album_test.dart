import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

/// An album of [count] photos with ids `0` … `count - 1`, handed out in the
/// pages the screen asks for.
class _AlbumClient extends PhotoviewClient {
  _AlbumClient(int count)
    : media = [
        for (var i = 0; i < count; i++)
          MediaItem(id: '$i', type: MediaType.photo, title: '$i.jpg'),
      ],
      super(_session);

  final List<MediaItem> media;
  final offsets = <int>[];

  @override
  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async {
    offsets.add(offset);
    return AlbumPage(
      title: 'Urlaub',
      media: media.skip(offset).take(limit).toList(),
      subAlbums: const [],
    );
  }
}

/// Opens the gallery on photo [mediaId] from a home screen, as a person's
/// page would, with or without the album button.
Future<void> _openGallery(
  WidgetTester tester,
  _AlbumClient client, {
  required String mediaId,
  bool showAlbumLink = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
        mediaDetailsProvider.overrideWith(
          (ref, id) async => MediaDetails(
            media: MediaItem(id: id, type: MediaType.photo),
            title: '$id.jpg',
            album: const MediaAlbum(id: '7', title: 'Urlaub'),
          ),
        ),
      ],
      child: localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenGallery(
              context,
              media: [MediaItem(id: mediaId, type: MediaType.photo)],
              initialIndex: 0,
              showAlbumLink: showAlbumLink,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('the gallery offers no album where it was not asked to', (
    tester,
  ) async {
    await _openGallery(tester, _AlbumClient(3), mediaId: '1', showAlbumLink: false);

    expect(find.byTooltip('Show in album'), findsNothing);
  });

  testWidgets('opens the album with the photo open in it', (tester) async {
    final client = _AlbumClient(3);
    await _openGallery(tester, client, mediaId: '1');
    expect(find.text('1 / 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Show in album'));
    await tester.pumpAndSettle();

    // The album's own gallery, over all of its photos, on the one tapped.
    expect(find.text('2 / 3'), findsOneWidget);
    expect(
      find.byTooltip('Show in album'),
      findsNothing,
      reason: 'in the album it would lead back to where the user is',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Urlaub'), findsOneWidget);

    // Back from the album returns to where the first gallery was opened,
    // not to that gallery again.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('loads further pages until the photo turns up', (tester) async {
    // The album comes 200 photos at a time; this one is in the second page.
    final client = _AlbumClient(250);
    await _openGallery(tester, client, mediaId: '230');

    await tester.tap(find.byTooltip('Show in album'));
    await tester.pumpAndSettle();

    expect(client.offsets, [0, 200]);
    expect(find.text('231 / 250'), findsOneWidget);
  });

  testWidgets('says so when the album does not hold the photo', (
    tester,
  ) async {
    // Moved or deleted since the person's page was loaded.
    final client = _AlbumClient(3);
    await _openGallery(tester, client, mediaId: '99');

    await tester.tap(find.byTooltip('Show in album'));
    await tester.pumpAndSettle();

    expect(find.text('Urlaub'), findsOneWidget);
    expect(find.text('This photo was not found in the album'), findsOneWidget);
  });
}
