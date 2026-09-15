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

  @override
  Future<File> fetch(
    Session session,
    String url, {
    required String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    fetched.add(url);
    final failure = failWith;
    if (failure != null) throw failure;
    return File('${directory.path}/$fileName')..writeAsBytesSync([1, 2, 3]);
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

  Future<_FakeFetcher> pump(WidgetTester tester, {Object? failWith}) async {
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
        child: const MaterialApp(
          home: Scaffold(
            body: DownloadButton(
              download: _original,
              mediaTitle: 'screenshots_01.jpg',
            ),
          ),
        ),
      ),
    );
    return fetcher;
  }

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
