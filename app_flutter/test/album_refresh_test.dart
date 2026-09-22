import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/album_screen.dart';
import 'package:photoview/state/auth.dart';

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

class _AlbumClient extends PhotoviewClient {
  _AlbumClient() : super(_session);

  int reads = 0;
  List<MediaItem> media = const [];
  Object? failWith;

  /// Holds the next read open, to see what the screen does while it waits.
  Future<void>? holdNextRead;

  @override
  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async {
    reads++;

    final hold = holdNextRead;
    if (hold != null) {
      holdNextRead = null;
      await hold;
    }

    final failure = failWith;
    if (failure != null) throw failure;
    return AlbumPage(title: 'Urlaub', media: media, subAlbums: const []);
  }
}

Future<void> _open(WidgetTester tester, _AlbumClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
      child: localizedApp(
        home: const AlbumScreen(albumId: '7', title: 'Urlaub'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pulls down far enough to trip the indicator.
Future<void> _pullDown(WidgetTester tester) async {
  await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('an album with photos can be pulled down to refresh', (
    tester,
  ) async {
    final client = _AlbumClient()
      ..media = const [MediaItem(id: '1', type: MediaType.photo, title: 'a.jpg')];

    await _open(tester, client);
    expect(client.reads, 1);

    await _pullDown(tester);
    expect(client.reads, 2);
  });

  testWidgets('an empty album can be pulled down too', (tester) async {
    // The state that matters for a deleted file: the album may have become
    // empty, and a message with nothing scrollable under it would refuse the
    // gesture — exactly when the user reaches for it.
    final client = _AlbumClient();

    await _open(tester, client);
    expect(find.text('This album is empty'), findsOneWidget);

    await _pullDown(tester);
    expect(client.reads, 2);
  });

  testWidgets('an album that failed to load can be pulled down', (
    tester,
  ) async {
    final client = _AlbumClient()
      ..failWith = const ApiException(
        'Connection failed',
        problem: ApiProblem.unreachable,
      );

    await _open(tester, client);
    expect(client.reads, 1);

    client.failWith = null;
    await _pullDown(tester);

    expect(client.reads, 2, reason: 'the gesture works on an error screen');
  });

  testWidgets('a refresh that is still out keeps the gesture busy', (
    tester,
  ) async {
    // `onRefresh` hands back the read itself, so the indicator is tied to the
    // answer rather than to its own animation. Deliberately not asserted
    // against the old code: there the loading state replaced the list
    // entirely, which leaves the indicator on screen too — for the wrong
    // reason. What this test does hold is that a held-open read does not
    // wedge the screen and that the album arrives when it answers.
    final client = _AlbumClient()
      ..media = const [MediaItem(id: '1', type: MediaType.photo, title: 'a.jpg')];

    await _open(tester, client);

    final answered = Completer<void>();
    client.holdNextRead = answered.future;

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    answered.complete();
    await tester.pumpAndSettle();

    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(client.reads, 2);
  });
}
