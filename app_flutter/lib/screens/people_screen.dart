import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../state/people_order.dart';
import '../widgets/action_failure.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/face_grid.dart';

class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  bool _recognizing = false;

  /// Asks the server to have another look at the faces nobody has named.
  ///
  /// It is the server that does the matching, against the people who already
  /// have a name — so this is worth pressing after naming someone, and does
  /// nothing on a library where nobody is named yet.
  ///
  /// It can take a while on a large library, which is why the button turns
  /// into a spinner rather than the screen staying as it was.
  Future<void> _recognize() async {
    final l10n = AppLocalizations.of(context);

    setState(() => _recognizing = true);
    try {
      final filed = await ref.read(faceActionsProvider).recognizeUnlabeled();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.peopleRecognized(filed))),
      );
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.peopleRecognizeFailed,
          retry: _recognize,
        );
      }
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final faces = ref.watch(faceGroupsProvider);

    return Scaffold(
      body: RefreshIndicator(
        // Awaited, as on the timeline: invalidating alone ends the spinner
        // before the new answer is in.
        onRefresh: () => ref.refresh(faceGroupsProvider.future),
        child: LoadMoreOnScroll(
          hasMore: faces.valueOrNull?.hasMore ?? false,
          onLoadMore: () => ref.read(faceGroupsProvider.notifier).loadMore(),
          child: ScrollableView(
          // See the note in timeline_screen.dart: a short list would otherwise
          // refuse the pull-to-refresh gesture.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              title: Text(AppLocalizations.of(context).navPeople),
              floating: true,
              snap: true,
              actions: [
                if (_recognizing)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.person_search_outlined),
                    tooltip: AppLocalizations.of(context).peopleRecognize,
                    onPressed: _recognize,
                  ),
              ],
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
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyMessage(
                      message: AppLocalizations.of(context).peopleEmpty,
                      icon: Icons.person_outline,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: FaceSliverGrid(
                      faceGroups: orderedFaceGroups(
                        data.groups,
                        ref.watch(peopleOrderProvider).valueOrNull ??
                            PeopleOrder.alphabetical,
                      ),
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
      ),
    );
  }
}
