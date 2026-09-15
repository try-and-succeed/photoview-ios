import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/timeline.dart';
import '../util/formatting.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
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
        child: LoadMoreOnScroll(
          hasMore: timeline.valueOrNull?.hasMore ?? false,
          onLoadMore: () => ref.read(timelineProvider.notifier).loadMore(),
          child: CustomScrollView(
          // Without this, a timeline that fits on screen — empty, still
          // loading, or showing an error — cannot be overscrolled, so the
          // pull-to-refresh gesture never fires exactly when it is wanted most.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              title: Text(AppLocalizations.of(context).navTimeline),
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
                  child: ErrorMessage.forError(
                    error,
                    onRetry: () => ref.invalidate(timelineProvider),
                  ),
                ),
              ],
              data: (data) => _timelineSlivers(context, ref, data),
            ),
          ],
          ),
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
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(AppLocalizations.of(context).timelineEmpty),
          ),
        ),
      ];
    }

    final slivers = <Widget>[];

    for (final group in data.groups) {
      slivers.add(
        SliverToBoxAdapter(child: _GroupHeader(group: group)),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          sliver: MediaSliverGrid(media: group.media),
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
