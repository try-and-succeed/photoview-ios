import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import 'auth.dart';
import 'capabilities.dart';
import 'stale_response_guard.dart';

/// One row of the flattened tree, ready to render.
class AlbumTreeRow {
  final AlbumItem album;

  /// 0 for a root, one more for each level below it.
  final int depth;
  final bool isExpanded;

  /// Null while it is not yet known whether this album has children, which is
  /// what keeps a disclosure arrow from appearing and then doing nothing.
  final bool? hasChildren;

  final bool isLoading;
  final String? error;

  const AlbumTreeRow({
    required this.album,
    required this.depth,
    required this.isExpanded,
    required this.hasChildren,
    this.isLoading = false,
    this.error,
  });
}

/// The tree as far as it has been explored.
class AlbumTreeState {
  /// Roots, or null while they are still loading.
  final List<AlbumItem>? roots;

  /// Error from loading the roots, kept apart from the per-node errors: a
  /// failure to load one branch must not look like the whole tree is broken.
  final String? rootsError;

  /// albumId -> its children, for every album already asked about.
  final Map<String, List<AlbumItem>> children;

  final Set<String> expanded;
  final Set<String> loading;
  final Map<String, String> errors;

  const AlbumTreeState({
    this.roots,
    this.rootsError,
    this.children = const {},
    this.expanded = const {},
    this.loading = const {},
    this.errors = const {},
  });

  AlbumTreeState copyWith({
    List<AlbumItem>? roots,
    String? rootsError,
    bool clearRootsError = false,
    Map<String, List<AlbumItem>>? children,
    Set<String>? expanded,
    Set<String>? loading,
    Map<String, String>? errors,
  }) => AlbumTreeState(
    roots: roots ?? this.roots,
    rootsError: clearRootsError ? null : (rootsError ?? this.rootsError),
    children: children ?? this.children,
    expanded: expanded ?? this.expanded,
    loading: loading ?? this.loading,
    errors: errors ?? this.errors,
  );

  bool get isLoadingRoots => roots == null && rootsError == null;

  /// Whether [album] is known to have children, or null if nobody has asked.
  bool? hasChildren(String albumId) => children[albumId]?.isNotEmpty;

  /// The visible rows, depth-first, narrowed to [filter].
  ///
  /// The filter is a parameter rather than part of this state because it
  /// belongs to the screen: it is what the user is typing right now, and
  /// leaving the screen should end it. Keeping it here meant the next visit
  /// reopened mid-search with an empty text field and no way to tell why.
  ///
  /// While a filter is set the tree is shown expanded down to the levels
  /// already loaded, because a match three levels down is useless if its
  /// ancestors are collapsed.
  List<AlbumTreeRow> rowsFor(String filter) {
    final all = roots;
    if (all == null) return const [];

    final needle = filter.trim().toLowerCase();
    final filtering = needle.isNotEmpty;

    // Each level builds its own list and hands it up. The earlier version
    // appended into one shared list and then copied each subtree out of it and
    // back again per node, which is quadratic: on a library of a couple of
    // thousand albums it froze the app on every keystroke.
    List<AlbumTreeRow> visit(List<AlbumItem> albums, int depth) {
      final rows = <AlbumTreeRow>[];

      for (final album in albums) {
        final kids = children[album.id] ?? const <AlbumItem>[];
        final open = filtering ? kids.isNotEmpty : expanded.contains(album.id);

        final subtree = open
            ? visit(kids, depth + 1)
            : const <AlbumTreeRow>[];

        // A row survives the filter if it matches, or if anything under it
        // does — otherwise a match would be unreachable.
        final matches =
            !filtering || album.title.toLowerCase().contains(needle);

        if (matches || subtree.isNotEmpty) {
          rows.add(
            AlbumTreeRow(
              album: album,
              depth: depth,
              isExpanded: open,
              hasChildren: hasChildren(album.id),
              isLoading: loading.contains(album.id),
              error: errors[album.id],
            ),
          );
          rows.addAll(subtree);
        }
      }

      return rows;
    }

    return visit(all, 0);
  }
}

class AlbumTreeNotifier extends Notifier<AlbumTreeState>
    with StaleResponseGuard {
  @override
  AlbumTreeState build() {
    // Watched here, while the provider is building, so the tree is rebuilt
    // from scratch when the session changes rather than mixing two servers.
    ref.watch(sessionProvider);

    // Rebuilding resets the state but keeps this notifier, so a request that
    // was already in flight against the previous server would write its albums
    // into the new one's tree. Every write past an await checks the generation.
    beginGeneration(ref);

    Future.microtask(loadRoots);
    return const AlbumTreeState();
  }

  Future<void> loadRoots() async {
    final generation = this.generation;
    state = state.copyWith(clearRootsError: true);

    try {
      final roots = await ref.guardedRead((c) => c.myAlbums());
      if (movedOn(generation)) return;

      state = state.copyWith(roots: roots);

      // One level ahead, in a single request: without it every root would show
      // a disclosure arrow that might reveal nothing.
      await _fetchChildrenOf(roots.map((a) => a.id).toList());
    } catch (error) {
      if (movedOn(generation)) return;
      state = state.copyWith(rootsError: '$error');
    }
  }

  Future<void> toggle(String albumId) async {
    if (state.expanded.contains(albumId)) {
      state = state.copyWith(expanded: {...state.expanded}..remove(albumId));
      return;
    }

    state = state.copyWith(expanded: {...state.expanded, albumId});

    final known = state.children[albumId];
    if (known != null) {
      // The children themselves are already here, so expanding is instant —
      // but the level below them is not, and without it the rows that just
      // appeared would show no disclosure arrows at all. Ask for that level,
      // which skips whatever is already known.
      await _fetchChildrenOf(
        known.map((a) => a.id).toList(),
        lookAhead: false,
      );
      return;
    }

    await _fetchChildrenOf([albumId]);
  }

  /// Retries one branch that failed, without touching the rest of the tree.
  Future<void> retry(String albumId) => _fetchChildrenOf([albumId]);

  /// Fetches the children of [albumIds], and — unless [lookAhead] is false —
  /// the children of those children as well.
  ///
  /// The lookahead is exactly one level deep, and must stay that way: letting
  /// it recurse would walk the entire album tree on the first open, which is
  /// the opposite of why this screen fetches level by level.
  Future<void> _fetchChildrenOf(
    List<String> albumIds, {
    bool lookAhead = true,
  }) async {
    // Skips what is already on its way too. Opening an album whose children
    // the lookahead is still fetching would otherwise ask twice — and if the
    // second request failed after the first had succeeded, its error would sit
    // next to children that loaded fine, where retry (which skips known
    // children) could never clear it.
    final wanted = albumIds
        .where(
          (id) =>
              !state.children.containsKey(id) && !state.loading.contains(id),
        )
        .toSet()
        .toList();
    if (wanted.isEmpty) return;

    final generation = this.generation;
    final serverId = ref.read(sessionProvider)?.serverId;

    state = state.copyWith(
      loading: {...state.loading, ...wanted},
      errors: {...state.errors}..removeWhere((id, _) => wanted.contains(id)),
    );

    try {
      final fetched = await ref.guardedRead(
        (c) => c.albumTreeChildren(wanted),
      );

      if (movedOn(generation)) return;
      state = state.copyWith(
        children: {...state.children, ...fetched},
        loading: {...state.loading}..removeAll(wanted),
      );

      if (!lookAhead) return;

      // Look one level further, so the arrows on what just appeared are right.
      final grandchildren = fetched.values
          .expand((children) => children.map((a) => a.id))
          .toList();
      if (grandchildren.isNotEmpty) {
        await _fetchChildrenOf(grandchildren, lookAhead: false);
      }
    } on UnsupportedFieldException catch (failure) {
      // The cache said this server has the tree and it does not — an entry
      // that was wrong, or a server that was rolled back. Record the
      // correction so the entry point disappears instead of offering a screen
      // whose every retry sends the same doomed request.
      if (serverId != null) {
        await ref.read(capabilityDowngradeProvider)(serverId, failure);
      }

      if (movedOn(generation)) return;
      state = state.copyWith(
        loading: {...state.loading}..removeAll(wanted),
        errors: {
          ...state.errors,
          for (final id in wanted) id: '$failure',
        },
      );
    } catch (error) {
      if (movedOn(generation)) return;
      state = state.copyWith(
        loading: {...state.loading}..removeAll(wanted),
        errors: {
          ...state.errors,
          for (final id in wanted) id: '$error',
        },
      );
    }
  }
}

final albumTreeProvider =
    NotifierProvider<AlbumTreeNotifier, AlbumTreeState>(
      AlbumTreeNotifier.new,
    );
