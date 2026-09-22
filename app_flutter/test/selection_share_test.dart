import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/media_files.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/album_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/download_button.dart';
import 'package:photoview/widgets/media_grid.dart';

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

final _media = [
  for (var i = 0; i < 4; i++)
    MediaItem(id: '$i', type: MediaType.photo, title: 'photo-$i.jpg'),
];

class _AlbumClient extends PhotoviewClient {
  _AlbumClient() : super(_session);

  @override
  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async => AlbumPage(title: 'Urlaub', media: _media, subAlbums: const []);
}

/// Writes a small file instead of fetching one, and records what was asked.
class _FakeFetcher extends MediaFileFetcher {
  _FakeFetcher(this.directory, {this.failFor = const {}});

  final Directory directory;

  /// Urls that fail, as a photo the server will not hand over does.
  final Set<String> failFor;

  final List<String> fetched = [];
  Completer<void>? hold;

  @override
  Future<File> fetch(
    Session session,
    String url, {
    required String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    fetched.add(url);

    final held = hold;
    if (held != null) await held.future;

    if (cancellation?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }
    if (failFor.contains(url)) throw const ApiException('nope');

    // Written synchronously: real async I/O never completes inside a widget
    // test's fake clock, so the loop would stop after the first file.
    return File('${directory.path}/$fileName')
      ..writeAsStringSync('bytes of $fileName');
  }
}

MediaDetails _detailsFor(String id) => MediaDetails(
  media: _media.firstWhere((m) => m.id == id),
  title: 'photo-$id.jpg',
  downloads: [
    MediaDownload(
      title: 'Small',
      url: '/api/photo/small-$id.jpg',
      width: 100,
      height: 100,
      fileSize: 10,
    ),
    MediaDownload(
      title: 'Original',
      url: '/api/photo/original-$id.jpg',
      width: 1000,
      height: 1000,
      fileSize: 1000,
    ),
  ],
);

Future<_FakeFetcher> _openAlbum(
  WidgetTester tester, {
  required Directory temp,
  required List<List<File>> shared,
  Set<String> failFor = const {},
}) async {
  final fetcher = _FakeFetcher(temp, failFor: failFor);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(_AlbumClient()),
        mediaFileFetcherProvider.overrideWithValue(fetcher),
        mediaDetailsProvider.overrideWith((ref, id) async => _detailsFor(id)),
        shareFilesProvider.overrideWithValue((files) async => shared.add(files)),
      ],
      child: localizedApp(
        home: const AlbumScreen(albumId: '7', title: 'Urlaub'),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return fetcher;
}

/// Long-presses the nth picture in the grid.
Future<void> _longPressTile(WidgetTester tester, int index) async {
  await tester.longPress(find.byType(MediaThumbnail).at(index));
  await tester.pumpAndSettle();
}

/// Runs the share to its end.
///
/// Pumped in steps rather than settled: the progress dialog spins forever by
/// design, and `pumpAndSettle` waits for an animation that never stops.
Future<void> _shareAndWait(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.ios_share));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late List<List<File>> shared;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('selection_share_test');
    shared = [];
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  testWidgets('a long press starts picking, a tap adds to it', (tester) async {
    await _openAlbum(tester, temp: temp, shared: shared);

    expect(find.text('Urlaub'), findsOneWidget, reason: 'the album title');

    await _longPressTile(tester, 0);
    expect(find.text('Selected: 1'), findsOneWidget);

    await tester.tap(find.byType(MediaThumbnail).at(2));
    await tester.pumpAndSettle();
    expect(find.text('Selected: 2'), findsOneWidget);

    // Tapping a ticked one again takes it back out.
    await tester.tap(find.byType(MediaThumbnail).at(2));
    await tester.pumpAndSettle();
    expect(find.text('Selected: 1'), findsOneWidget);
  });

  testWidgets('taking the last one out leaves the mode', (tester) async {
    await _openAlbum(tester, temp: temp, shared: shared);

    await _longPressTile(tester, 1);
    await tester.tap(find.byType(MediaThumbnail).at(1));
    await tester.pumpAndSettle();

    expect(find.text('Urlaub'), findsOneWidget, reason: 'back to the album');
    expect(find.textContaining('Selected:'), findsNothing);
  });

  testWidgets('select all ticks everything loaded', (tester) async {
    await _openAlbum(tester, temp: temp, shared: shared);

    await _longPressTile(tester, 0);
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 4'), findsOneWidget);
  });

  testWidgets('sharing sends the originals of what was ticked', (tester) async {
    final fetcher = await _openAlbum(tester, temp: temp, shared: shared);

    await _longPressTile(tester, 0);
    await tester.tap(find.byType(MediaThumbnail).at(3));
    await tester.pumpAndSettle();

    await _shareAndWait(tester);

    expect(
      fetcher.fetched,
      ['/api/photo/original-0.jpg', '/api/photo/original-3.jpg'],
      reason: 'the full-size file is what sharing a photo means',
    );
    expect(shared.single, hasLength(2));

    // And the mode is over, because the job is done.
    expect(find.text('Urlaub'), findsOneWidget);
  });

  testWidgets('one photo that fails does not sink the rest', (tester) async {
    await _openAlbum(
      tester,
      temp: temp,
      shared: shared,
      failFor: {'/api/photo/original-1.jpg'},
    );

    await _longPressTile(tester, 0);
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    await _shareAndWait(tester);

    expect(shared.single, hasLength(3), reason: 'three of four still go');
    expect(find.textContaining('Could not be fetched: 1'), findsOneWidget);
  });

  testWidgets('the count is shown while fetching, and can be cancelled', (
    tester,
  ) async {
    final fetcher = await _openAlbum(tester, temp: temp, shared: shared);
    fetcher.hold = Completer<void>();

    await _longPressTile(tester, 0);
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pump();

    expect(find.textContaining('Fetching pictures'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    fetcher.hold!.complete();
    await tester.pumpAndSettle();

    expect(shared, isEmpty, reason: 'a cancelled share sends nothing');
  });
}
