import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import '../widgets/async_states.dart';
import '../widgets/face_grid.dart';

class PeopleScreen extends ConsumerWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faces = ref.watch(faceGroupsProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(faceGroupsProvider),
        child: CustomScrollView(
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
                  child: ErrorMessage(
                    message: '$error',
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
                    sliver: FaceSliverGrid(
                      faceGroups: data.groups,
                      onItemBuilt: (index) {
                        if (data.groups.length - index >=
                            faceGroupPrefetchThreshold) {
                          return;
                        }

                        // Deferred: the grid reports this from inside build,
                        // and loadMore writes provider state straight away.
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) =>
                              ref.read(faceGroupsProvider.notifier).loadMore(),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
