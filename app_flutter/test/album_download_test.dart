import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/media_files.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/util/formatting.dart';
import 'package:photoview/widgets/album_download.dart';
import 'package:photoview/widgets/download_button.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// A download the test drives by hand: it reports progress when told, and
/// finishes, fails or notices a cancel when told.
class _ScriptedFetcher extends MediaFileFetcher {
  final Directory directory;
  final finish = Completer<Object?>();
  String? requestedUrl;
  String? requestedName;
  void Function(int received)? progress;

  _ScriptedFetcher(this.directory);

  @override
  Future<File> fetch(
    Session session,
    String url, {
    required String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    requestedUrl = url;
    requestedName = fileName;
    progress = onProgress;
    cancellation?.whenCancelled.then((_) {
      if (!finish.isCompleted) finish.complete(const DownloadCancelledException());
    });

    final outcome = await finish.future;
    if (outcome is Exception) throw outcome;
    return File('${directory.path}/$fileName')..writeAsBytesSync([80, 75]);
  }
}

void main() {
  late Directory temp;
  late _ScriptedFetcher fetcher;
  late List<(String path, String name)> saved;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('album_download_test');
    fetcher = _ScriptedFetcher(temp);
    saved = [];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(_session),
          mediaFileFetcherProvider.overrideWithValue(fetcher),
          saveFileProvider.overrideWithValue((file, name) async {
            saved.add((file.path, name));
            return '/storage/emulated/0/Download/$name';
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => downloadAlbum(
                  context,
                  ref,
                  albumId: '4',
                  albumTitle: 'Screenshots',
                ),
                child: const Text('download'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('download'));
    await tester.pump();
  }

  /// Lets the file work and the dialog's pop through, then settles.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('downloads the originals as a ZIP and saves it', (tester) async {
    await start(tester);

    expect(fetcher.requestedUrl, '/api/download/album/4/original');
    expect(find.text('Screenshots.zip'), findsOneWidget);

    fetcher.finish.complete(null);
    await settle(tester);

    expect(saved.single.$2, 'Screenshots.zip');
    expect(find.text('Saved Screenshots.zip'), findsOneWidget);
    expect(File(saved.single.$1).existsSync(), isFalse, reason: 'cache copy removed');
  });

  testWidgets('shows how much has arrived', (tester) async {
    await start(tester);

    // Past the refresh interval, so the count on screen is updated.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    fetcher.progress!(5 * 1024 * 1024);
    await tester.pump();

    expect(find.text('${formatBytes(5 * 1024 * 1024)} received'), findsOneWidget);

    fetcher.finish.complete(null);
    await settle(tester);
  });

  testWidgets('Cancel stops the download and saves nothing', (tester) async {
    await start(tester);

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(saved, isEmpty);
    expect(find.text('Download cancelled'), findsOneWidget);
    expect(find.text('Downloading album'), findsNothing);
  });

  testWidgets('what the server refused is shown', (tester) async {
    await start(tester);

    fetcher.finish.complete(
      const ApiException('The server returned HTTP 400: no media found'),
    );
    await settle(tester);

    expect(saved, isEmpty);
    expect(find.textContaining('no media found'), findsOneWidget);
  });
}
