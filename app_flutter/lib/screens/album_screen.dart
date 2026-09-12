import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';

class AlbumScreen extends ConsumerWidget {
  final String albumId;
  final String title;

  const AlbumScreen({super.key, required this.albumId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumProvider(albumId));

    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
                    // loadMore writes provider state straight away.
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => ref.read(albumProvider(albumId).notifier).loadMore(),
                    );
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
