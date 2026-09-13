import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/timeline.dart';
import '../util/formatting.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';
import 'album_screen.dart';
import 'search_screen.dart';

class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(timelineProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(timelineProvider);
          await ref.read(timelineProvider.future);
        },
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              title: const Text('Timeline'),
              floating: true,
              snap: true,
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => showPhotoviewSearch(context),
                ),
              ],
            ),
            ...timeline.when(
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
                    onRetry: () => ref.invalidate(timelineProvider),
                  ),
                ),
              ],
              data: (data) => _timelineSlivers(context, ref, data),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _timelineSlivers(
    BuildContext context,
    WidgetRef ref,
    TimelineData data,
  ) {
    if (data.groups.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('No media in your timeline yet')),
        ),
      ];
    }

    final slivers = <Widget>[];

    // Running offset of each group within the flat media list, so the grids can
    // tell how close the user is to the end of what has been loaded.
    var groupStart = 0;

    for (final group in data.groups) {
      final start = groupStart;
      groupStart += group.media.length;

      slivers.add(
        SliverToBoxAdapter(child: _GroupHeader(group: group)),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          sliver: MediaSliverGrid(
            media: group.media,
            onItemBuilt: (index) {
              final remaining = data.mediaCount - (start + index);
              if (remaining >= timelinePrefetchThreshold) return;

              // Deferred: the grid reports this from inside build, and
              // loadMore writes provider state straight away. The screen may
              // be gone once the frame completes.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                ref.read(timelineProvider.notifier).loadMore();
              });
            },
          ),
        ),
      );
    }

    if (data.loadingMore) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));

    return slivers;
  }
}

class _GroupHeader extends StatelessWidget {
  final TimelineGroup group;

  const _GroupHeader({required this.group});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              AlbumScreen(albumId: group.albumId, title: group.albumTitle),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatDay(group.day),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    group.albumTitle,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
