import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/search_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/search_limit.dart';
import 'package:photoview/widgets/search_results.dart';

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

/// Answers a search with as many hits as it was asked for, so a result that
/// fills the limit — which is how the app tells "cut off" from "that is all"
/// — can be arranged by asking for it.
class _CountingSearchClient extends PhotoviewClient {
  _CountingSearchClient({required this.available}) : super(_session);

  /// How many hits exist per kind on this imaginary server.
  final int available;

  final List<int?> askedFor = [];

  @override
  Future<SearchResults> search(
    String query, {
    int? limitMedia,
    int? limitAlbums,
  }) async {
    askedFor.add(limitMedia);

    final limit = limitMedia == null || limitMedia == 0
        ? available
        : limitMedia;
    final count = limit < available ? limit : available;

    return SearchResults(
      query: query,
      albums: [
        for (var i = 0; i < count; i++) AlbumItem(id: 'a$i', title: 'Album $i'),
      ],
      media: [
        for (var i = 0; i < count; i++)
          MediaItem(id: 'm$i', type: MediaType.photo, title: 'photo-$i.jpg'),
      ],
    );
  }
}

Future<void> _search(
  WidgetTester tester,
  _CountingSearchClient client, {
  int? limitSetting,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
        searchLimitProvider.overrideWith(
          (ref) async => SearchLimit(
            value: limitSetting,
            source: SearchLimitSource.device,
          ),
        ),
      ],
      child: localizedApp(home: const SearchScreen()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField), 'urlaub');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('a full page of hits offers to show them all', (tester) async {
    // Ten of ten looks the same as ten of ten thousand, so the offer is made
    // whenever the answer filled the limit.
    final client = _CountingSearchClient(available: 300);
    await _search(tester, client, limitSetting: 10);

    expect(find.text('Show all results'), findsOneWidget);
    expect(
      client.askedFor,
      [10],
      reason: 'the first search still uses the setting',
    );
  });

  testWidgets('a short answer offers nothing', (tester) async {
    final client = _CountingSearchClient(available: 3);
    await _search(tester, client, limitSetting: 10);

    expect(find.text('Show all results'), findsNothing);
  });

  testWidgets('showing all asks for everything the screen can hold', (
    tester,
  ) async {
    // Not for "no limit at all": measured against a real library, one word
    // brought 2.7 MB and four seconds that way, to fill a list that stops at
    // five hundred anyway.
    final client = _CountingSearchClient(available: 300);
    await _search(tester, client, limitSetting: 10);

    await tester.tap(find.text('Show all results'));
    await tester.pumpAndSettle();

    expect(client.askedFor, [10, maxRenderedSearchResults + 1]);
    expect(
      find.text('Show all results'),
      findsNothing,
      reason: 'nothing left to ask for',
    );
    expect(find.textContaining('Albums · 300'), findsOneWidget);
  });

  testWidgets('more than the screen can hold is said as such', (tester) async {
    // One hit past the ceiling is all the app knows: it asked for one more
    // than it can show, so "1 more not shown" would be a lie.
    final client = _CountingSearchClient(available: 5000);
    await _search(tester, client, limitSetting: 10);

    await tester.tap(find.text('Show all results'));
    await tester.pumpAndSettle();

    // The heading is what is on screen; the note sits below five hundred rows,
    // which a viewport never builds. It gets its own test below.
    expect(find.textContaining('Albums · 500+'), findsOneWidget);
  });

  testWidgets('the note at the ceiling does not invent a total', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(
          body: HiddenResultsNote(hidden: 1, atCeiling: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('More than 500 hits'), findsOneWidget);
    expect(
      find.textContaining('1 more not shown'),
      findsNothing,
      reason: 'one past the ceiling is not one more in total',
    );
  });

  testWidgets('a known total is still named exactly', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: const Scaffold(body: HiddenResultsNote(hidden: 250)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('250 more not shown'), findsOneWidget);
  });

  testWidgets('a new search starts small again', (tester) async {
    final client = _CountingSearchClient(available: 300);
    await _search(tester, client, limitSetting: 10);

    await tester.tap(find.text('Show all results'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'berge');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(client.askedFor.last, 10, reason: 'the setting is back in charge');
    expect(find.text('Show all results'), findsOneWidget);
  });

  testWidgets('a keystroke still in flight does not undo showing all', (
    tester,
  ) async {
    // Submitting with the keyboard leaves the timer from the last keystroke
    // armed. It fires a moment later with the same words, and used to clear
    // "show all" with it — so a list the user had just asked to see in full
    // snapped back to the first few on its own.
    final client = _CountingSearchClient(available: 300);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
          searchLimitProvider.overrideWith(
            (ref) async =>
                const SearchLimit(value: 10, source: SearchLimitSource.device),
          ),
        ],
        child: localizedApp(home: const SearchScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'urlaub');
    await tester.testTextInput.receiveAction(TextInputAction.search);

    // Short of the debounce, so that timer is still out there.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('Show all results'));
    await tester.pump();

    // Now let the stale timer land.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Show all results'), findsNothing);
    expect(client.askedFor.last, maxRenderedSearchResults + 1);
  });

  testWidgets('an unlimited setting has nothing more to offer', (tester) async {
    // Zero means unlimited — measured — so everything is already there.
    final client = _CountingSearchClient(available: 300);
    await _search(tester, client, limitSetting: 0);

    expect(find.text('Show all results'), findsNothing);
  });
}
