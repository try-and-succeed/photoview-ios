import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../state/scanner.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
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

    try {
      await ref.read(scannerProvider.notifier).scanAlbum(albumId);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Scanning this album and its sub-albums.'),
          action: SnackBarAction(
            label: 'Show',
            onPressed: () => showScanner(context),
          ),
        ),
      );
    } catch (error) {
      // Deliberately not retried: the server may already have accepted the
      // request, and a second one would run all the same.
      messenger.showSnackBar(
        SnackBar(content: Text('Could not start the scan: $error')),
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
          if (ref.watch(hasCapabilityProvider(Capability.scanner)))
            IconButton(
              icon: const Icon(Icons.radar),
              tooltip: 'Scan for new media',
              onPressed: () => _scan(context, ref),
            ),
        ],
      ),
      body: album.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage(
          message: '$error',
          onRetry: () => ref.invalidate(albumProvider(albumId)),
        ),
        data: (data) {
          if (data.subAlbums.isEmpty && data.media.isEmpty) {
            return const EmptyMessage(message: 'This album is empty');
          }

          return CustomScrollView(
            slivers: [
              if (data.subAlbums.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: AlbumSliverGrid(albums: data.subAlbums),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                sliver: MediaSliverGrid(
                  media: data.media,
                  onItemBuilt: (index) {
                    if (data.media.length - index >= albumPrefetchThreshold) {
                      return;
                    }

                    // Deferred: the grid reports this from inside build, and
                    // loadMore writes provider state straight away. By the
                    // time the frame is done the screen may be gone, so the
                    // element has to be checked before reading from it.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!context.mounted) return;
                      ref.read(albumProvider(albumId).notifier).loadMore();
                    });
                  },
                ),
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
          );
        },
      ),
    );
  }
}
