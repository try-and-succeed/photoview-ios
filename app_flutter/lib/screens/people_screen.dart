import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/face_grid.dart';

class PeopleScreen extends ConsumerWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faces = ref.watch(faceGroupsProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(faceGroupsProvider),
        child: LoadMoreOnScroll(
          hasMore: faces.valueOrNull?.hasMore ?? false,
          onLoadMore: () => ref.read(faceGroupsProvider.notifier).loadMore(),
          child: CustomScrollView(
          // See the note in timeline_screen.dart: a short list would otherwise
          // refuse the pull-to-refresh gesture.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            const SliverAppBar(
              title: Text('People'),
              floating: true,
              snap: true,
            ),
            ...faces.when(
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
                    onRetry: () => ref.invalidate(faceGroupsProvider),
                  ),
                ),
              ],
              data: (data) => [
                if (data.groups.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyMessage(
                      message:
                          'No faces recognised yet.\nFace detection runs on the server.',
                      icon: Icons.person_outline,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: FaceSliverGrid(faceGroups: data.groups),
                  ),
                if (data.loadingMore)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ],
          ),
        ),
      ),
    );
  }
}
