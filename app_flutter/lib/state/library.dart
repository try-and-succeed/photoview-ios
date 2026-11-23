import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import 'auth.dart';
import 'capabilities.dart';
import 'stale_response_guard.dart';
import 'people_order.dart' show faceGroupIsNamed, unnamedFewestFirstProvider;
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

  /// Whether the server paged the unnamed fewest photos first. Kept with the
  /// groups so they are shown in the order they were fetched in, even while a
  /// changed setting is still being fetched anew.
  final bool fewestFirst;

  /// The server account these people belong to, so that fetching them again
  /// keeps the length of the list only for the same account.
  final String? serverId;

  const FaceGroupsData({
    this.groups = const [],
    this.hasMore = true,
    this.loadingMore = false,
    this.fewestFirst = false,
    this.serverId,
  });

  FaceGroupsData copyWith({
    List<FaceGroup>? groups,
    bool? hasMore,
    bool? loadingMore,
  }) => FaceGroupsData(
    groups: groups ?? this.groups,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    fewestFirst: fewestFirst,
    serverId: serverId,
  );
}

class FaceGroupsNotifier extends AsyncNotifier<FaceGroupsData>
    with StaleResponseGuard {
  var _fewestFirst = false;

  /// Whether each person comes with whether all their faces are confirmed.
  var _withStatus = false;

  @override
  Future<FaceGroupsData> build() async {
    beginGeneration(ref);
    final generation = this.generation;

    // A plain bool, so switching between orders that page the same way — A to
    // Z and Z to A — re-sorts what is there instead of fetching it again.
    _fewestFirst = ref.watch(unnamedFewestFirstProvider);
    _withStatus = ref.watch(_faceStatusProvider);
    // Watched, not read: the people are labelled with the account they came
    // from, and a label taken before the sign-in had settled would be wrong
    // for good — every later fetch would take them for another account's, and
    // cut the list back to one page.
    final serverId = ref.watch(sessionProvider)?.serverId;

    // As many as were there before, when this is the same account fetching
    // again — after a move, say. Riverpod keeps the old list on screen
    // meanwhile, but a new one cut back to its first page put a user who had
    // scrolled far down at its end, far above where they were. Not after the
    // direction changed: the list then starts with other people anyway.
    final before = _stateOrNull?.valueOrNull;
    final keep =
        before != null &&
            before.serverId == serverId &&
            before.fewestFirst == _fewestFirst
        ? before.groups.length
        : 0;

    List<FaceGroup> first;
    try {
      first = await ref.guarded(
        (c) => c.faceGroups(
          limit: _faceGroupPageSize,
          offset: 0,
          fewestFirst: _fewestFirst,
          withStatus: _withStatus,
        ),
      );
    } on UnsupportedFieldException catch (failure) {
      final ruledOut = failure.ruledOut;
      final noOrder =
          _fewestFirst && ruledOut.contains(Capability.faceGroupCountDirection);
      final noStatus =
          _withStatus && ruledOut.contains(Capability.faceVerification);
      if (!noOrder && !noStatus) rethrow;

      // The cache said this server can page fewest first, or tell confirmed
      // people apart, and it cannot — a server rolled back, most likely.
      // Recorded so the list stops asking, and answered without meanwhile
      // rather than with an error.
      if (serverId != null) {
        await ref.read(capabilityDowngradeProvider)(serverId, failure);
      }
      // Not once a newer fetch has taken over: the order is shared with it,
      // and switching it here mixed two orders into its list. The downgrade
      // above still stands — the server did refuse.
      if (movedOn(generation)) rethrow;
      if (noOrder) _fewestFirst = false;
      if (noStatus) _withStatus = false;
      first = await _page(0);
    }

    return _throughTheNamed(
      first,
      keep: keep,
      serverId: serverId,
      generation: generation,
    );
  }

  /// The state as it stands, or null before the first build has produced one.
  AsyncValue<FaceGroupsData>? get _stateOrNull {
    try {
      return state;
    } catch (_) {
      return null;
    }
  }

  Future<List<FaceGroup>> _page(int offset) {
    final fewestFirst = _fewestFirst;
    final withStatus = _withStatus;

    // `guardedRead`, not `guarded`: this runs after an await, where watching
    // the client would attach to a build that has already finished.
    return ref.guardedRead(
      (c) => c.faceGroups(
        limit: _faceGroupPageSize,
        offset: offset,
        fewestFirst: fewestFirst,
        withStatus: withStatus,
      ),
    );
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
  ///
  /// Also keeps fetching until there are at least [keep] people, so a list
  /// fetched again is as long as it was.
  ///
  /// Stops once a newer fetch has replaced this one ([generation] is the
  /// build's). Riverpod drops an overtaken build's result but does not stop
  /// it, and two moves in quick succession left the first fetch paging on up
  /// to the old length — a hundred requests for a long list — beside the one
  /// that replaced it.
  Future<FaceGroupsData> _throughTheNamed(
    List<FaceGroup> first, {
    required int generation,
    int keep = 0,
    String? serverId,
  }) async {
    final groups = [...first];
    var lastPage = first;
    var hasMore = first.length >= _faceGroupPageSize;

    while (!movedOn(generation) &&
        hasMore &&
        lastPage.isNotEmpty &&
        (lastPage.every(faceGroupIsNamed) || groups.length < keep)) {
      lastPage = await _page(groups.length);
      groups.addAll(lastPage);
      hasMore = lastPage.length >= _faceGroupPageSize;
    }

    return FaceGroupsData(
      groups: groups,
      hasMore: hasMore,
      fewestFirst: _fewestFirst,
      serverId: serverId,
    );
  }

  Future<void> loadMore() async {
    // Not while the whole list is being fetched again: that fetch brings at
    // least as many as there are, and a page added to the old list would only
    // be overwritten by it.
    if (state.isLoading) return;

    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    final generation = this.generation;
    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await _page(current.groups.length);

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

/// Whether faces carry their confirmation and review flags on this server.
///
/// Watched by the face providers, so they fetch with the flags once the
/// capability is known — the first answer, while it is still being asked,
/// comes without.
final _faceStatusProvider = Provider<bool>(
  (ref) => ref.watch(hasCapabilityProvider(Capability.faceVerification)),
);

final personPhotosProvider = FutureProvider.family<List<PersonPhoto>, String>((
  ref,
  faceGroupId,
) {
  final withStatus = ref.watch(_faceStatusProvider);
  return ref.guarded(
    (c) => c.personPhotos(faceGroupId, withStatus: withStatus),
  );
});

final placesMarkersProvider = FutureProvider<List<PlacesMarker>>(
  (ref) => ref.guarded((c) => c.mediaGeoJson()),
);

/// Keyed by the joined ids because family arguments are compared with `==`,
/// and a `List` would create a fresh provider on every rebuild.
final clusterMediaProvider = FutureProvider.family<List<MediaItem>, String>(
  (ref, joinedIds) => ref.guarded(
    (c) => c.mediaList(joinedIds.split(',')..removeWhere((s) => s.isEmpty)),
  ),
);

final mediaDetailsProvider = FutureProvider.family<MediaDetails, String>(
  (ref, mediaId) => ref.guarded((c) => c.mediaDetails(mediaId)),
);

/// Who is on a photo. Auto-disposed: asked for only while the gallery shows
/// the faces, and stale the moment any face moves.
final mediaFacesProvider = FutureProvider.autoDispose
    .family<List<PhotoFace>, String>((ref, mediaId) {
      final withStatus = ref.watch(_faceStatusProvider);
      return ref.guarded(
        (c) => c.mediaFaces(mediaId, withStatus: withStatus),
      );
    });

const _reviewPageSize = 100;

class ReviewMediaData {
  final List<MediaItem> media;
  final bool hasMore;
  final bool loadingMore;

  const ReviewMediaData({
    this.media = const [],
    this.hasMore = true,
    this.loadingMore = false,
  });

  ReviewMediaData copyWith({
    List<MediaItem>? media,
    bool? hasMore,
    bool? loadingMore,
  }) => ReviewMediaData(
    media: media ?? this.media,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// The photos with a face an automatic run placed and nobody has looked at
/// yet, newest first and paged.
///
/// Fetched from the start again after every face action: confirming a photo
/// takes it off the list, so an offset counted before would skip photos.
class ReviewMediaNotifier extends AsyncNotifier<ReviewMediaData>
    with StaleResponseGuard {
  @override
  Future<ReviewMediaData> build() async {
    beginGeneration(ref);
    final page = await ref.guarded(
      (c) => c.mediaNeedingReview(limit: _reviewPageSize, offset: 0),
    );
    return ReviewMediaData(
      media: page,
      hasMore: page.length >= _reviewPageSize,
    );
  }

  Future<void> loadMore() async {
    if (state.isLoading) return;
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    final generation = this.generation;
    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await ref.guardedRead(
        (c) => c.mediaNeedingReview(
          limit: _reviewPageSize,
          offset: current.media.length,
        ),
      );

      if (movedOn(generation)) return;
      // A photo can come twice when one before it left the list meanwhile
      // and the pages shifted; it is shown once.
      final known = {for (final item in current.media) item.id};
      state = AsyncData(
        current.copyWith(
          media: [
            ...current.media,
            for (final item in page)
              if (!known.contains(item.id)) item,
          ],
          hasMore: page.length >= _reviewPageSize,
          loadingMore: false,
        ),
      );
    } catch (error, stack) {
      if (movedOn(generation)) return;
      state = AsyncError(error, stack);
    }
  }
}

final reviewMediaProvider =
    AsyncNotifierProvider<ReviewMediaNotifier, ReviewMediaData>(
      ReviewMediaNotifier.new,
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
final shareActionsProvider = Provider<ShareActions>((ref) => ShareActions(ref));

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

/// Every action here also drops what the gallery knows about whose faces are
/// on which photo: each of them changes a name or a face's person.
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
    _ref.invalidate(mediaFacesProvider);
    return stored;
  }

  /// "Everyone named on this photo is right": confirms [named], and marks
  /// [unnamedToReview] as looked at without confirming them.
  ///
  /// Nothing moves; what changes is how the faces are drawn, which photos a
  /// person's filters hold, the review list, and which people carry the mark
  /// of being confirmed throughout.
  ///
  /// The unnamed are left unconfirmed on purpose. To the server, a confirmed
  /// face without a name is someone of their own: it is never moved by a run
  /// again, and it pulls similar faces in. Not knowing a face says neither.
  /// But the server clears the review flag only on confirming, so those
  /// faces are confirmed and at once taken back — which leaves the flag
  /// cleared. Two requests; if the second fails, the error says so and a
  /// retry sends both again, which changes nothing that is right already.
  Future<void> verifyPhoto({
    required List<String> named,
    required List<String> unnamedToReview,
  }) async {
    if (named.isEmpty && unnamedToReview.isEmpty) return;
    final client = _ref.requireClient;
    try {
      await client.setImageFacesVerified([
        ...named,
        ...unnamedToReview,
      ], verified: true);
      if (unnamedToReview.isNotEmpty) {
        await client.setImageFacesVerified(unnamedToReview, verified: false);
      }
    } finally {
      // Also after a failure halfway: the first request may have changed
      // the faces already.
      _statusChanged();
    }
  }

  /// Confirms [imageFaceIds], or takes the confirmation back — one person's
  /// faces on the ticked photos, not the other people on them; the named on
  /// a photo; or one unnamed face kept as someone of their own.
  Future<int> verifyFaces(
    List<String> imageFaceIds, {
    required bool verified,
  }) async {
    if (imageFaceIds.isEmpty) return 0;
    final changed = await _ref.requireClient.setImageFacesVerified(
      imageFaceIds,
      verified: verified,
    );
    _statusChanged();
    return changed;
  }

  void _statusChanged() {
    // The people list marks who is confirmed throughout. Fetched again as
    // long as it was (see FaceGroupsNotifier.build), so the place in it
    // stays; invalidating twice, as a move does with its own call, still
    // fetches once.
    _ref.invalidate(faceGroupsProvider);
    _ref.invalidate(mediaFacesProvider);
    _ref.invalidate(personPhotosProvider);
    _ref.invalidate(reviewMediaProvider);
  }

  /// Files the unconfirmed faces of [faceGroupId] again, comparing them with
  /// the confirmed faces of everybody — or, as a [dryRun], says what that
  /// would do without changing anything.
  Future<ReclassifyResult> reclassify(
    String faceGroupId, {
    required bool dryRun,
  }) async {
    final result = await _ref.requireClient.reclassifyFaceGroups([
      faceGroupId,
    ], dryRun: dryRun);

    if (!dryRun) {
      // Faces left this person for others and for new people, and every one
      // that was looked at now waits for review: all of it is out of date.
      _ref.invalidate(faceGroupsProvider);
      _statusChanged();
    }
    return result;
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
    _ref.invalidate(mediaFacesProvider);
    _ref.invalidate(personPhotosProvider(destination));
    return label;
  }

  /// The server's proposals to join unnamed groups that look alike. A dry
  /// run: nothing changes.
  Future<List<MergeProposal>> mergeProposals() =>
      _ref.requireClient.mergeSimilarUnlabeledFaceGroups(dryRun: true);

  /// Carries out [merges] one after another, telling [onDone] after each how
  /// many are through.
  ///
  /// One by one with `combineFaceGroups` rather than the server's real run,
  /// which merges every proposal it finds: that would take the ones the user
  /// turned down, and whole groups the user took out of a proposal, along
  /// with the rest. The lists are dropped once at the end, not after each —
  /// a hundred merges would otherwise fetch the people a hundred times — and
  /// also when one fails halfway, since those before it went through.
  Future<void> mergeAll(
    List<({String destination, List<String> sources})> merges, {
    void Function(int done)? onDone,
  }) async {
    final client = _ref.requireClient;
    var done = 0;
    try {
      for (final merge in merges) {
        await client.combineFaceGroups(merge.destination, merge.sources);
        onDone?.call(++done);
      }
    } finally {
      if (done > 0) {
        _ref.invalidate(faceGroupsProvider);
        _ref.invalidate(mediaFacesProvider);
        _ref.invalidate(personPhotosProvider);
      }
    }
  }

  /// Files [imageFaceIds] under [destination] — photos of this person that
  /// are somebody else.
  ///
  /// Returns the destination's name afterwards. Two people change, so both
  /// their photo lists go, and the counts on the people list with them.
  ///
  /// Also onto a photo the destination is on already: see
  /// [PhotoviewClient.moveImageFaces].
  Future<String?> moveFaces(
    List<String> imageFaceIds,
    String destination,
  ) async {
    if (imageFaceIds.isEmpty) return null;

    final label = await _ref.requireClient.moveImageFaces(
      imageFaceIds,
      destination,
    );

    _ref.invalidate(faceGroupsProvider);
    // A face moved by hand counts as confirmed on a server that knows about
    // confirming, and leaves the review list with that.
    _statusChanged();
    return label;
  }

  /// Lifts [imageFaceIds] out into a person of their own, returning the new
  /// group's id.
  ///
  /// This is also the only way back out of a merge that was wrong: the server
  /// has no undo, and no delete either.
  ///
  /// **An empty list is refused here rather than sent.** The server does not
  /// treat it as a mistake — it creates an empty face group, which then sits
  /// in the library with nothing in it.
  Future<String?> detachFaces(List<String> imageFaceIds) async {
    if (imageFaceIds.isEmpty) return null;

    final created = await _ref.requireClient.detachImageFaces(imageFaceIds);

    _ref.invalidate(faceGroupsProvider);
    _statusChanged();
    return created;
  }

  /// Asks the server to match the unnamed faces against the named ones again,
  /// returning how many it filed.
  Future<int> recognizeUnlabeled() async {
    final filed = await _ref.requireClient.recognizeUnlabeledFaces();

    // Whatever it matched moved from an unnamed group into a named one.
    _ref.invalidate(faceGroupsProvider);
    _ref.invalidate(mediaFacesProvider);

    // The whole family, because the server decides which people grew — and
    // unlike a merge, nothing here says which. A person's photo list does not
    // rebuild with the people list; it would otherwise keep showing what it
    // read before the match, however long the screen stays open.
    // The review list too: a server that knows about review flags every
    // face the match filed.
    _statusChanged();
    return filed;
  }
}
