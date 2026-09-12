import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import 'search_screen.dart';

class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(myAlbumsProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myAlbumsProvider),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              title: const Text('My albums'),
              floating: true,
              snap: true,
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => showPhotoviewSearch(context),
                ),
              ],
            ),
            ...albums.when(
              loading: () => [
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (error, _) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorMessage(
                    message: '$error',
                    onRetry: () => ref.invalidate(myAlbumsProvider),
                  ),
                ),
              ],
              data: (data) => [
                if (data.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyMessage(
                      message: 'No albums found',
                      icon: Icons.photo_album_outlined,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: AlbumSliverGrid(albums: data),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
