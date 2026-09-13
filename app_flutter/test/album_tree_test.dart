import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/album_tree.dart';
import 'package:photoview/state/auth.dart';

AlbumItem _album(String id, String title) =>
    AlbumItem(id: id, title: title);

/// Familie(2) -> Geburtstage(6) -> Opa-80(13)
/// Natur(3)   -> Berge(8)
/// Screenshots(4) has no children.
const _roots = ['2', '3', '4'];

final _tree = <String, List<AlbumItem>>{
  '2': [_album('6', 'Geburtstage')],
  '3': [_album('8', 'Berge')],
  '4': [],
  '6': [_album('13', 'Opa-80')],
  '8': [],
  '13': [],
};

AlbumTreeState _state({
  Set<String> expanded = const {},
  Map<String, List<AlbumItem>>? children,
  Set<String> loading = const {},
  Map<String, String> errors = const {},
}) => AlbumTreeState(
  roots: [
    _album('2', 'Familie'),
    _album('3', 'Natur'),
    _album('4', 'Screenshots'),
  ],
  children: children ?? _tree,
  expanded: expanded,
  loading: loading,
  errors: errors,
);

void main() {
  group('AlbumTreeState.rows', () {
    test('collapsed, only the roots are visible', () {
      final rows = _state().rowsFor('');

      expect(rows.map((r) => r.album.id), _roots);
      expect(rows.every((r) => r.depth == 0), isTrue);
    });

    test('expanding one node reveals only its children', () {
      final rows = _state(expanded: {'2'}).rowsFor('');

      expect(rows.map((r) => r.album.id), ['2', '6', '3', '4']);
      expect(rows[1].depth, 1);
    });

    test('depth grows with each level', () {
      final rows = _state(expanded: {'2', '6'}).rowsFor('');

      expect(rows.map((r) => r.album.id), ['2', '6', '13', '3', '4']);
      expect(rows.map((r) => r.depth), [0, 1, 2, 0, 0]);
    });

    test('an album with no children reports so, and one unasked does not', () {
      final rows = _state(
        children: {'2': [_album('6', 'Geburtstage')], '4': []},
      ).rowsFor('');

      final byId = {for (final r in rows) r.album.id: r};
      expect(byId['2']!.hasChildren, isTrue);
      expect(byId['4']!.hasChildren, isFalse);
      // Nobody has asked about 3 yet: null, not false. The screen draws no
      // arrow for it rather than one that might reveal nothing.
      expect(byId['3']!.hasChildren, isNull);
    });

    test('builds a tree from a partial answer without failing', () {
      // The server filters out ids the user may not see, so an answer can be
      // missing entries. That is not an error.
      final rows = _state(
        expanded: {'2', '3'},
        children: {'2': [_album('6', 'Geburtstage')]},
      ).rowsFor('');

      expect(rows.map((r) => r.album.id), ['2', '6', '3', '4']);
    });

    test('carries per-node loading and error state', () {
      final rows = _state(
        expanded: {'2'},
        loading: {'3'},
        errors: {'4': 'boom'},
      ).rowsFor('');

      final byId = {for (final r in rows) r.album.id: r};
      expect(byId['3']!.isLoading, isTrue);
      expect(byId['4']!.error, 'boom');
      // A failing branch leaves the rest of the tree alone.
      expect(byId['2']!.error, isNull);
      expect(byId['6'], isNotNull);
    });
  });

  group('AlbumTreeState.rows while filtering', () {
    test('keeps a match and everything needed to reach it', () {
      // Opa-80 is two levels down. Showing it without its ancestors would
      // leave it unreachable, so the path is kept even though "Familie" and
      // "Geburtstage" do not match.
      final rows = _state().rowsFor('opa');

      expect(rows.map((r) => r.album.id), ['2', '6', '13']);
    });

    test('drops branches with no match anywhere in them', () {
      final rows = _state().rowsFor('berge');

      expect(rows.map((r) => r.album.id), ['3', '8']);
    });

    test('matches a root on its own', () {
      final rows = _state().rowsFor('screenshots');

      expect(rows.map((r) => r.album.id), ['4']);
    });

    test('ignores case', () {
      expect(_state().rowsFor('natur'), isNotEmpty);
      expect(_state().rowsFor('berge').length, 2);
    });

    test('no match at all yields nothing', () {
      expect(_state().rowsFor('nothing matches this'), isEmpty);
    });

    test('a filtered tree is shown open regardless of what was expanded', () {
      // A match three levels down is useless if its ancestors are collapsed.
      final rows = _state().rowsFor('opa');

      expect(rows.map((r) => r.album.id), ['2', '6', '13']);
      expect(rows.first.isExpanded, isTrue);
    });
  });

  group('AlbumTreeState.rows on a real-sized library', () {
    /// Roughly the shape of the test server's benchmark library: a few roots,
    /// then years, then months — 2 200-odd albums over four levels.
    late AlbumTreeState big;

    setUpAll(() {
      final children = <String, List<AlbumItem>>{};
      final roots = <AlbumItem>[];

      var next = 0;
      String id() => 'a${next++}';

      for (var r = 0; r < 5; r++) {
        final root = _album(id(), 'Root $r');
        roots.add(root);

        final years = <AlbumItem>[];
        for (var y = 0; y < 6; y++) {
          final year = _album(id(), '200$y');
          years.add(year);

          final months = <AlbumItem>[];
          for (var m = 0; m < 12; m++) {
            final month = _album(id(), 'Month $m');
            months.add(month);

            final days = <AlbumItem>[];
            for (var d = 0; d < 8; d++) {
              final day = _album(id(), 'Day $d');
              days.add(day);
              children[day.id] = const [];
            }
            children[month.id] = days;
          }
          children[year.id] = months;
        }
        children[root.id] = years;
      }

      big = AlbumTreeState(
        roots: roots,
        children: children,
        expanded: children.keys.toSet(),
      );
    });

    test('flattens a few thousand albums without stalling', () {
      // The first implementation copied each node's subtree out of a shared
      // list and back, which is quadratic — on this many albums it froze the
      // app on every keystroke. The budget is deliberately loose; the point is
      // that quadratic behaviour blows past it by orders of magnitude.
      final clock = Stopwatch()..start();
      final rows = big.rowsFor('');
      clock.stop();

      expect(rows, hasLength(5 + 5 * 6 + 5 * 6 * 12 + 5 * 6 * 12 * 8));
      expect(clock.elapsedMilliseconds, lessThan(500));
    });

    test('filters a few thousand albums without stalling', () {
      final clock = Stopwatch()..start();
      final rows = big.rowsFor('month 3');
      clock.stop();

      expect(rows, isNotEmpty);
      expect(clock.elapsedMilliseconds, lessThan(500));
    });
  });

  group('AlbumTreeNotifier fetching', () {
    /// Records every batch of ids the notifier asks for, so the shape of the
    /// traffic can be asserted rather than just the end state.
    late _RecordingClient client;
    late ProviderContainer container;

    setUp(() async {
      client = _RecordingClient();
      container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authProvider.future);
      container.read(albumTreeProvider);
      await pumpEventQueue();
    });

    test('asks for a whole level in one request, not one per album', () {
      // This is the point of albumTreeChildren: the roots' children arrive in
      // a single round trip.
      expect(client.batches.first.toSet(), {'2', '3', '4'});
    });

    test('looks exactly one level ahead and then stops', () {
      // Without a depth limit the lookahead recurses and walks the entire
      // album tree on the first open — the opposite of fetching level by
      // level. Roots, then the roots' children, and nothing further.
      expect(client.batches, hasLength(2));
      expect(client.batches[0].toSet(), {'2', '3', '4'});
      expect(client.batches[1].toSet(), {'6', '8'});
      expect(
        client.batches.expand((b) => b),
        isNot(contains('13')),
        reason: 'a third level must not be fetched before it is asked for',
      );
    });

    test('expanding never re-asks for children already held', () async {
      client.batches.clear();

      await container.read(albumTreeProvider.notifier).toggle('2');

      expect(container.read(albumTreeProvider).expanded, contains('2'));
      expect(
        client.batches.expand((b) => b),
        isNot(contains('2')),
        reason: "2's children are already known",
      );
    });

    test('the first level down needs no extra request', () async {
      // The roots' lookahead already covered it, so opening a root is free
      // and the rows it reveals already know whether they can be opened.
      client.batches.clear();

      await container.read(albumTreeProvider.notifier).toggle('2');

      expect(client.batches, isEmpty);
      expect(container.read(albumTreeProvider).hasChildren('6'), isTrue);
    });

    test('expanding deeper looks one level past what it reveals', () async {
      // Opening 6 shows 13, whose children nobody has asked about — without
      // this step 13 would carry no disclosure arrow even if it has children.
      final notifier = container.read(albumTreeProvider.notifier);
      await notifier.toggle('2');
      client.batches.clear();

      await notifier.toggle('6');

      expect(client.batches.single.toSet(), {'13'});
      expect(container.read(albumTreeProvider).hasChildren('13'), isFalse);
    });

    test('collapsing keeps what was fetched', () async {
      final notifier = container.read(albumTreeProvider.notifier);
      await notifier.toggle('2');
      await notifier.toggle('2');

      expect(container.read(albumTreeProvider).expanded, isNot(contains('2')));
      expect(container.read(albumTreeProvider).children, contains('2'));
    });

    test('deduplicates before asking', () async {
      client.batches.clear();
      await container.read(albumTreeProvider.notifier).retry('2');

      // 2 is already known, so nothing is asked for again.
      expect(client.batches, isEmpty);
    });
  });

  group('AlbumTreeState', () {
    test('distinguishes loading the roots from having none', () {
      const loading = AlbumTreeState();
      expect(loading.isLoadingRoots, isTrue);
      expect(loading.rowsFor(''), isEmpty);

      const empty = AlbumTreeState(roots: []);
      expect(empty.isLoadingRoots, isFalse);
      expect(empty.rowsFor(''), isEmpty);
    });

    test('a roots error is not a loading state', () {
      const failed = AlbumTreeState(rootsError: 'no network');

      expect(failed.isLoadingRoots, isFalse);
      expect(failed.rootsError, 'no network');
    });
  });
}

final _testSession = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _testSession;
}

/// A client backed by [_tree], recording which ids each request asked for.
class _RecordingClient extends PhotoviewClient {
  _RecordingClient() : super(_testSession);

  final List<List<String>> batches = [];

  @override
  Future<List<AlbumItem>> myAlbums() async => [
    _album('2', 'Familie'),
    _album('3', 'Natur'),
    _album('4', 'Screenshots'),
  ];

  @override
  Future<Map<String, List<AlbumItem>>> albumTreeChildren(
    List<String> albumIds,
  ) async {
    final unique = albumIds.toSet().toList();
    batches.add(unique);

    return {for (final id in unique) id: _tree[id] ?? const []};
  }
}
