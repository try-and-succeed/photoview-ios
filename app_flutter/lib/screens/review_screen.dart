import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/media_grid.dart';
import '../widgets/scrollable_view.dart';

/// The photos with a face an automatic run placed and nobody has checked —
/// after a re-identification, or after the unnamed were matched.
///
/// Across all people, because a run sends faces to other people too: the
/// photos to check are not only the ones still under the person it ran on.
/// A photo opens with its faces framed; confirming it, or filing a face by
/// hand, takes it off this list.
class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final review = ref.watch(reviewMediaProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.reviewTitle)),
      body: RefreshIndicator(
        // Awaited, so the spinner stays until the answer is in.
        onRefresh: () => ref.refresh(reviewMediaProvider.future),
        child: LoadMoreOnScroll(
          hasMore: review.valueOrNull?.hasMore ?? false,
          onLoadMore: () => ref.read(reviewMediaProvider.notifier).loadMore(),
          child: ScrollableView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: review.when(
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
                    onRetry: () => ref.invalidate(reviewMediaProvider),
                  ),
                ),
              ],
              data: (data) => [
                if (data.media.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyMessage(
                      message: l10n.reviewEmpty,
                      icon: Icons.task_alt,
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Text(l10n.reviewHint),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    sliver: MediaSliverGrid(
                      media: data.media,
                      showFacesInGallery: true,
                    ),
                  ),
                ],
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
          ),
        ),
      ),
    );
  }
}
