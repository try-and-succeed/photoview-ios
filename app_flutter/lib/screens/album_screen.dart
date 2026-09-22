import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../state/scanner.dart';
import '../widgets/action_failure.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/album_download.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/media_grid.dart';
import '../widgets/share_selection.dart';
import 'scanner_screen.dart';

class AlbumScreen extends ConsumerStatefulWidget {
  final String albumId;
  final String title;

  const AlbumScreen({super.key, required this.albumId, required this.title});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  /// Ids the user has ticked. Empty means the picking mode is not running —
  /// there is no separate flag, because an empty selection and no selection
  /// are the same thing to everything that reads this.
  final Set<String> _selected = {};

  String get albumId => widget.albumId;
  String get title => widget.title;

  void _toggle(MediaItem item) => setState(() {
    if (!_selected.remove(item.id)) _selected.add(item.id);
  });

  void _clearSelection() => setState(_selected.clear);

  /// Starts a scan and points the user at the queue.
  ///
  /// What gets queued are this album's sub-albums, so the queue will usually
  /// not list this album by name — the message says so rather than leaving the
  /// user to wonder whether anything happened.
  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);

    // Captured before the await: the SnackBar outlives this screen, and its
    // action must not look a Navigator up from a context that is by then
    // deactivated.
    final navigator = Navigator.of(context);

    try {
      await ref.read(scannerProvider.notifier).scanAlbum(albumId);

      // One message at a time: tapping twice otherwise queues two identical
      // answers, and a later failure waits behind them.
      messenger
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.albumScanStarted),
            action: SnackBarAction(
              label: l10n.actionShow,
              onPressed: () => showScanner(navigator),
            ),
          ),
        );
    } catch (error) {
      if (!context.mounted) return;

      // Never retried on its own: the server may already have accepted the
      // request, and a second one would run all the same. Accepting a
      // certificate is the user asking for exactly that, so that path — and
      // only that one — tries again.
      await showActionFailure(
        context,
        ref,
        error: error,
        message: l10n.albumScanFailed,
        retry: () => _scan(context, ref),
      );
    }
  }

  /// Sends the ticked photos to another app, then leaves the picking mode.
  Future<void> _shareSelection(List<MediaItem> media) async {
    final chosen = [for (final item in media) if (_selected.contains(item.id)) item];
    if (chosen.isEmpty) return;

    await shareSelectedMedia(context, ref, chosen);
    if (mounted) _clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final album = ref.watch(albumProvider(albumId));
    final l10n = AppLocalizations.of(context);
    final loaded = album.valueOrNull?.media ?? const <MediaItem>[];
    final picking = _selected.isNotEmpty;

    return PopScope(
      // Back leaves the picking mode rather than the album: that is what it
      // undoes, and losing a selection of thirty photos to a stray swipe is
      // the kind of thing nobody tries twice.
      canPop: !picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: _scaffold(context, album, l10n, loaded, picking),
    );
  }

  Widget _scaffold(
    BuildContext context,
    AsyncValue<AlbumData> album,
    AppLocalizations l10n,
    List<MediaItem> loaded,
    bool picking,
  ) {
    return Scaffold(
      // Leaving the picking mode has to be the first thing to hand, which is
      // where "back" lives.
      appBar: picking
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.selectionCancel,
                onPressed: _clearSelection,
              ),
              title: Text(l10n.selectionCount(_selected.length)),
              actions: [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: l10n.selectionAll,
                  onPressed: loaded.isEmpty
                      ? null
                      : () => setState(() {
                          _selected
                            ..clear()
                            ..addAll([for (final item in loaded) item.id]);
                        }),
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: l10n.selectionShare,
                  onPressed: () => _shareSelection(loaded),
                ),
              ],
            )
          : AppBar(
              title: Text(title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: l10n.albumDownloadTooltip,
                  onPressed: () => downloadAlbum(
                    context,
                    ref,
                    albumId: albumId,
                    albumTitle: title,
                  ),
                ),
                if (ref.watch(hasCapabilityProvider(Capability.scanner)))
                  IconButton(
                    icon: const Icon(Icons.radar),
                    tooltip: l10n.albumScanTooltip,
                    onPressed: () => _scan(context, ref),
                  ),
              ],
            ),
      // The one list that had no way to be refreshed. Everything else is
      // pulled down; here the only way to see that a file had been deleted on
      // disk was to sign out and back in.
      //
      // Every state is a sliver in one scroll view, as on the other screens:
      // a RefreshIndicator needs something scrollable under it, and an album
      // that is empty or failed to load is exactly when the user reaches for
      // the gesture.
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(albumProvider(albumId).future),
        child: LoadMoreOnScroll(
          hasMore: album.valueOrNull?.hasMore ?? false,
          onLoadMore: () => ref.read(albumProvider(albumId).notifier).loadMore(),
          child: ScrollableView(
            // See the note in timeline_screen.dart: a short list would
            // otherwise refuse the pull-to-refresh gesture.
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              ...album.when(
                loading: () => [
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                error: (error, _) => [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: ErrorMessage.forError(
                      error,
                      onRetry: () => ref.invalidate(albumProvider(albumId)),
                    ),
                  ),
                ],
                data: (data) => [
                  if (data.subAlbums.isEmpty && data.media.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyMessage(
                        message: AppLocalizations.of(context).albumEmpty,
                      ),
                    )
                  else ...[
                    if (data.subAlbums.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.all(16),
                        sliver: AlbumSliverGrid(albums: data.subAlbums),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      sliver: MediaSliverGrid(
                        media: data.media,
                        selection: MediaSelection(
                          selected: _selected,
                          onToggle: _toggle,
                        ),
                      ),
                    ),
                    if (data.loadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ],
                ],
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }
}
