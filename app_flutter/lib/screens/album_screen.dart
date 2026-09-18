import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../state/scanner.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/album_download.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/media_grid.dart';
import 'scanner_screen.dart';

class AlbumScreen extends ConsumerWidget {
  final String albumId;
  final String title;

  const AlbumScreen({super.key, required this.albumId, required this.title});

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
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.albumScanStarted),
          action: SnackBarAction(
            label: l10n.actionShow,
            onPressed: () => showScanner(navigator),
          ),
        ),
      );
    } catch (error) {
      // Deliberately not retried: the server may already have accepted the
      // request, and a second one would run all the same.
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.albumScanFailed(describeError(error, l10n)))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumProvider(albumId));

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: AppLocalizations.of(context).albumDownloadTooltip,
            onPressed: () =>
                downloadAlbum(context, ref, albumId: albumId, albumTitle: title),
          ),
          if (ref.watch(hasCapabilityProvider(Capability.scanner)))
            IconButton(
              icon: const Icon(Icons.radar),
              tooltip: AppLocalizations.of(context).albumScanTooltip,
              onPressed: () => _scan(context, ref),
            ),
        ],
      ),
      body: album.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage.forError(
          error,
          onRetry: () => ref.invalidate(albumProvider(albumId)),
        ),
        data: (data) {
          if (data.subAlbums.isEmpty && data.media.isEmpty) {
            return EmptyMessage(
              message: AppLocalizations.of(context).albumEmpty,
            );
          }

          return LoadMoreOnScroll(
            hasMore: data.hasMore,
            onLoadMore: () =>
                ref.read(albumProvider(albumId).notifier).loadMore(),
            child: ScrollableView(
            slivers: [
              if (data.subAlbums.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: AlbumSliverGrid(albums: data.subAlbums),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                sliver: MediaSliverGrid(media: data.media),
              ),
              if (data.loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
            ),
          );
        },
      ),
    );
  }
}
