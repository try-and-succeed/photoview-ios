import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import 'album_tree_screen.dart';
import 'search_screen.dart';

class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(myAlbumsProvider);

    // Gated on the query alone, not on the `showAlbumTree` preference. That
    // preference is a separate capability, so asking for it in the same
    // document as the search limit would make one missing field break the
    // other's read — and it means "show the tree sidebar" in the web client,
    // which is not obviously a statement about a phone.
    final showTree = ref.watch(hasCapabilityProvider(Capability.albumTree));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myAlbumsProvider),
        child: CustomScrollView(
          // See the note in timeline_screen.dart: a short list would otherwise
          // refuse the pull-to-refresh gesture.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              title: const Text('My albums'),
              floating: true,
              snap: true,
              actions: [
                // Absent unless the server can answer for a whole level at
                // once. Walking album by album still works either way, so an
                // older server loses the shortcut, not the navigation.
                if (showTree)
                  IconButton(
                    icon: const Icon(Icons.account_tree_outlined),
                    tooltip: 'Album tree',
                    onPressed: () => showAlbumTree(context),
                  ),
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
                  child: ErrorMessage.forError(
                    error,
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
