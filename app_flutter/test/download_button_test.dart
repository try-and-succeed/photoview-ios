import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/media_files.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/widgets/download_button.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

const _original = MediaDownload(
  title: 'Original',
  url: '/api/photo/screenshots_01_PBXdCHRa.jpg',
  width: 1200,
  height: 1600,
  fileSize: 97084,
);

/// Serves a small file into a temporary directory instead of the network.
class _FakeFetcher extends MediaFileFetcher {
  final Directory directory;
  final Object? failWith;
  final List<String> fetched = [];

  _FakeFetcher(this.directory, {this.failWith});

  /// When set, the download waits for it — a transfer still under way.
  Completer<void>? hold;

  /// Whether a cancel ends the held download, as a real transfer does.
  bool honoursCancel = true;

  DownloadCancellation? lastCancellation;
  File? lastFile;

  @override
  Future<File> fetch(
    Session session,
    String url, {
    required String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    fetched.add(url);
    lastCancellation = cancellation;
    final failure = failWith;
    if (failure != null) throw failure;

    final held = hold;
    if (held != null) {
      await Future.any([
        held.future,
        if (honoursCancel && cancellation != null) cancellation.whenCancelled,
      ]);
      if (honoursCancel && (cancellation?.isCancelled ?? false)) {
        throw const DownloadCancelledException();
      }
    }

    return lastFile = File('${directory.path}/$fileName')
      ..writeAsBytesSync([1, 2, 3]);
  }
}

void main() {
  late Directory temp;
  late List<(String path, String fileName)> saved;
  late List<String> shared;
  String? saveAnswer;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('download_button_test');
    saved = [];
    shared = [];
    saveAnswer = '/storage/emulated/0/Download/screenshots_01.jpg';
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<_FakeFetcher> pump(
    WidgetTester tester, {
    Object? failWith,
    Locale? locale,
    MediaDownload download = _original,
  }) async {
    final fetcher = _FakeFetcher(temp, failWith: failWith);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(_session),
          mediaFileFetcherProvider.overrideWithValue(fetcher),
          saveFileProvider.overrideWithValue((file, fileName) async {
            saved.add((file.path, fileName));
            return saveAnswer;
          }),
          shareFileProvider.overrideWithValue((file) async => shared.add(file.path)),
        ],
        child: localizedApp(
          locale: locale,
          home: Scaffold(
            body: DownloadButton(
              download: download,
              mediaTitle: 'screenshots_01.jpg',
            ),
          ),
        ),
      ),
    );
    return fetcher;
  }

  testWidgets('speaks the app language, rendition name included', (
    tester,
  ) async {
    await pump(
      tester,
      locale: const Locale('de'),
      download: const MediaDownload(
        title: 'Large',
        url: '/api/photo/screenshots_01_large.jpg',
        width: 1200,
        height: 1600,
        fileSize: 2500,
      ),
    );

    expect(find.text('Groß'), findsOneWidget);
    expect(find.textContaining('2,5 kB'), findsOneWidget);
    expect(find.byTooltip('An andere App senden'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Groß'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.text('screenshots_01_large.jpg gespeichert'), findsOneWidget);
  });

  testWidgets('tapping saves the file under its library name', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Original'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(saved.single.$2, 'screenshots_01.jpg');
    expect(shared, isEmpty, reason: 'saving no longer opens the share sheet');
    expect(find.text('Saved screenshots_01.jpg'), findsOneWidget);
    expect(
      File(saved.single.$1).existsSync(),
      isFalse,
      reason: 'the cached copy is removed once the dialog has made its own',
    );
  });

  testWidgets('the share button sends the file to another app', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Send to another app'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(shared.single, endsWith('screenshots_01.jpg'));
    expect(saved, isEmpty);
  });

  testWidgets('cancelling the save dialog reports nothing', (tester) async {
    saveAnswer = null;
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Original'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(find.textContaining('Saved'), findsNothing);
  });

  testWidgets('closing the sheet stops a download under way', (tester) async {
    final fetcher = await pump(tester);
    fetcher.hold = Completer<void>();

    await tester.tap(find.text('Original'));
    await tester.pump();
    expect(fetcher.lastCancellation, isNotNull);
    expect(fetcher.lastCancellation!.isCancelled, isFalse);

    // The sheet goes away with the download still running.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

    expect(fetcher.lastCancellation!.isCancelled, isTrue);
    expect(saved, isEmpty);
  });

  testWidgets('a file that arrives after the sheet closed is removed', (
    tester,
  ) async {
    // A transfer that ignores the cancel and completes anyway.
    final fetcher = await pump(tester);
    fetcher
      ..hold = Completer<void>()
      ..honoursCancel = false;

    await tester.tap(find.text('Original'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.runAsync(() async {
      fetcher.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    expect(fetcher.lastFile, isNotNull);
    expect(fetcher.lastFile!.existsSync(), isFalse);
    expect(saved, isEmpty);
  });

  testWidgets('a failed download says so and saves nothing', (tester) async {
    await pump(tester, failWith: const ApiException('The server returned HTTP 500'));

    await tester.runAsync(() async {
      await tester.tap(find.text('Original'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
    expect(find.textContaining('Download failed'), findsOneWidget);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
  });
}
