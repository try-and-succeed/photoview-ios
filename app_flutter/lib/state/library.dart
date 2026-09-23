import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth.dart';
import 'stale_response_guard.dart';
import 'people_order.dart' show faceGroupIsNamed;
import 'search_limit.dart';

const _albumPageSize = 200;

final myAlbumsProvider = FutureProvider<List<AlbumItem>>(
  (ref) => ref.guarded((c) => c.myAlbums()),
);

/// Face groups are fetched in small pages: the server resolves a thumbnail per
/// group, which is slow enough that asking for all of them at once times out.
const _faceGroupPageSize = 40;

class FaceGroupsData {
  final List<FaceGroup> groups;
  final bool hasMore;
  final bool loadingMore;

  const FaceGroupsData({
    this.groups = const [],
    this.hasMore = true,
    this.loadingMore = false,
  });

  FaceGroupsData copyWith({
    List<FaceGroup>? groups,
    bool? hasMore,
    bool? loadingMore,
  }) => FaceGroupsData(
    groups: groups ?? this.groups,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

class FaceGroupsNotifier extends AsyncNotifier<FaceGroupsData>
    with StaleResponseGuard {
  @override
  Future<FaceGroupsData> build() async {
    beginGeneration(ref);

    final first = await ref.guarded(
      (c) => c.faceGroups(limit: _faceGroupPageSize, offset: 0),
    );

    return _throughTheNamed(first);
  }

  /// Keeps fetching while a page holds nothing but named people.
  ///
  /// The server sends every named person before the first unnamed one, and the
  /// app puts the named ones in its own order — by name, normally. That order
  /// can only be right once they are all here; a name arriving with a later
  /// page would otherwise have to slot in above wherever the user has scrolled
  /// to, moving the list under their thumb.
  ///
  /// This costs extra requests only for someone who has named more than a page
  /// full of people, which is who it is for.
  Future<FaceGroupsData> _throughTheNamed(List<FaceGroup> first) async {
    final groups = [...first];
    var lastPage = first;
    var hasMore = first.length >= _faceGroupPageSize;

    while (hasMore && lastPage.isNotEmpty && lastPage.every(faceGroupIsNamed)) {
      // `guardedRead`, not `guarded`: watching the client after an await would
      // attach to a build that has already finished.
      lastPage = await ref.guardedRead(
        (c) => c.faceGroups(limit: _faceGroupPageSize, offset: groups.length),
      );
      groups.addAll(lastPage);
      hasMore = lastPage.length >= _faceGroupPageSize;
    }

    return FaceGroupsData(groups: groups, hasMore: hasMore);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    final generation = this.generation;
    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await ref.guardedRead(
        (c) => c.faceGroups(
          limit: _faceGroupPageSize,
          offset: current.groups.length,
        ),
      );

      if (movedOn(generation)) return;
      state = AsyncData(
        current.copyWith(
          groups: [...current.groups, ...page],
          hasMore: page.length >= _faceGroupPageSize,
          loadingMore: false,
        ),
      );
    } catch (error, stack) {
      if (movedOn(generation)) return;
      state = AsyncError(error, stack);
    }
  }
}

final faceGroupsProvider =
    AsyncNotifierProvider<FaceGroupsNotifier, FaceGroupsData>(
      FaceGroupsNotifier.new,
    );

final personMediaProvider = FutureProvider.family<List<MediaItem>, String>(
  (ref, faceGroupId) => ref.guarded((c) => c.personMedia(faceGroupId)),
);

final placesMarkersProvider = FutureProvider<List<PlacesMarker>>(
  (ref) => ref.guarded((c) => c.mediaGeoJson()),
);

/// Keyed by the joined ids because family arguments are compared with `==`,
/// and a `List` would create a fresh provider on every rebuild.
final clusterMediaProvider = FutureProvider.family<List<MediaItem>, String>(
  (ref, joinedIds) =>
      ref.guarded((c) => c.mediaList(joinedIds.split(',')..removeWhere((s) => s.isEmpty))),
);

final mediaDetailsProvider = FutureProvider.family<MediaDetails, String>(
  (ref, mediaId) => ref.guarded((c) => c.mediaDetails(mediaId)),
);

/// Auto-disposed so the results of every intermediate keystroke are not kept.
/// What a search asks for.
///
/// [limit] overrides the user's preference for this one search — what "show
/// all results" sends, so asking for more does not change the setting. Null
/// leaves the preference in charge.
typedef SearchRequest = ({String query, int? limit});

final searchProvider = FutureProvider.autoDispose
    .family<SearchResults, SearchRequest>((ref, request) async {
      final query = request.query;
      if (query.trim().isEmpty) return SearchResults(query: query);

      // Waiting on the limit rather than firing without it: the limit resolves
      // from the cache on all but the first search, and starting with the
      // server default only to re-query would make results jump about.
      //
      // The future is watched here and awaited inside the callback, because
      // `ref.guarded` watches the client — awaiting first would put that watch
      // after an await, against a build that may already be gone.
      final limit = ref.watch(searchLimitProvider.future);

      return ref.guarded((c) async {
        final asked = request.limit ?? (await limit).limitArgument;

        return c.search(query, limitMedia: asked, limitAlbums: asked);
      });
    });

class AlbumData {
  final String title;
  final List<AlbumItem> subAlbums;
  final List<MediaItem> media;
  final bool hasMore;
  final bool loadingMore;

  const AlbumData({
    required this.title,
    this.subAlbums = const [],
    this.media = const [],
    this.hasMore = true,
    this.loadingMore = false,
  });

  AlbumData copyWith({
    List<MediaItem>? media,
    bool? hasMore,
    bool? loadingMore,
  }) => AlbumData(
    title: title,
    subAlbums: subAlbums,
    media: media ?? this.media,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

class AlbumNotifier extends FamilyAsyncNotifier<AlbumData, String>
    with StaleResponseGuard {
  @override
  Future<AlbumData> build(String albumId) async {
    beginGeneration(ref);

    final page = await ref.guarded(
      (c) => c.album(albumId: albumId, limit: _albumPageSize, offset: 0),
    );

    return AlbumData(
      title: page.title,
      subAlbums: page.subAlbums,
      media: page.media,
      hasMore: page.media.length >= _albumPageSize,
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    final generation = this.generation;
    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await ref.guardedRead(
        (c) => c.album(
          albumId: arg,
          limit: _albumPageSize,
          offset: current.media.length,
        ),
      );

      if (movedOn(generation)) return;
      state = AsyncData(
        current.copyWith(
          media: [...current.media, ...page.media],
          hasMore: page.media.length >= _albumPageSize,
          loadingMore: false,
        ),
      );
    } catch (error, stack) {
      if (movedOn(generation)) return;
      state = AsyncError(error, stack);
    }
  }
}

final albumProvider =
    AsyncNotifierProvider.family<AlbumNotifier, AlbumData, String>(
      AlbumNotifier.new,
    );

/// Share links are created and revoked through mutations, then the details
/// query is refetched so the list reflects the server.
final shareActionsProvider = Provider<ShareActions>(
  (ref) => ShareActions(ref),
);

class ShareActions {
  final Ref _ref;
  const ShareActions(this._ref);

  Future<void> addShare(String mediaId) async {
    await _ref.requireClient.shareMedia(mediaId);
    _ref.invalidate(mediaDetailsProvider(mediaId));
  }

  Future<void> deleteShare(String mediaId, String token) async {
    await _ref.requireClient.deleteShareToken(token);
    _ref.invalidate(mediaDetailsProvider(mediaId));
  }
}

/// Naming people.
///
/// Face groups belong to the user who owns the photos, so this is not a
/// permission question and needs nothing the upstream server lacks:
/// `setFaceGroupLabel` has always been part of the schema. The app simply
/// never used it, and names could only be given in the web interface.
final faceActionsProvider = Provider<FaceActions>((ref) => FaceActions(ref));

class FaceActions {
  final Ref _ref;
  const FaceActions(this._ref);

  /// Names [faceGroupId], or removes the name when [label] is null.
  ///
  /// Returns what the server stored, which is what the People tab will show —
  /// not what was sent.
  Future<String?> rename(String faceGroupId, String? label) async {
    final stored = await _ref.requireClient.setFaceGroupLabel(
      faceGroupId,
      label,
    );

    // The grid holds the old name until it is fetched again.
    _ref.invalidate(faceGroupsProvider);
    return stored;
  }

  /// Files [sources] under [destination], which is how two tiles of the same
  /// person become one.
  ///
  /// Returns the name the destination carries afterwards — the server keeps
  /// its own, so merging a named person into an unnamed one leaves it unnamed.
  Future<String?> merge(String destination, List<String> sources) async {
    final label = await _ref.requireClient.combineFaceGroups(
      destination,
      sources,
    );

    // The sources are gone and the destination has grown: both lists say
    // something that is no longer true.
    _ref.invalidate(faceGroupsProvider);
    _ref.invalidate(personMediaProvider(destination));
    return label;
  }

  /// Asks the server to match the unnamed faces against the named ones again,
  /// returning how many it filed.
  Future<int> recognizeUnlabeled() async {
    final filed = await _ref.requireClient.recognizeUnlabeledFaces();

    // Whatever it matched moved from an unnamed group into a named one.
    _ref.invalidate(faceGroupsProvider);

    // The whole family, because the server decides which people grew — and
    // unlike a merge, nothing here says which. A person's photo list does not
    // rebuild with the people list; it would otherwise keep showing what it
    // read before the match, however long the screen stays open.
    _ref.invalidate(personMediaProvider);
    return filed;
  }
}
