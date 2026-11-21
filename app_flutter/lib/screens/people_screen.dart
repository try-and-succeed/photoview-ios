import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../l10n/app_localizations.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../state/people_order.dart';
import '../widgets/action_failure.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/load_more.dart';
import '../widgets/face_grid.dart';
import '../widgets/face_move.dart' show personMatches;
import 'review_screen.dart';

class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  bool _recognizing = false;

  /// Whether the name field is open in place of the title.
  bool _searching = false;
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Closes the name field and shows everybody again.
  void _stopSearching() => setState(() {
    _searching = false;
    _query.clear();
  });

  /// Says what an action of this tab does and asks whether to go ahead.
  ///
  /// The app bar shows only icons, and a tap on one used to act at once —
  /// with no way to find out beforehand what it was about to do.
  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return yes == true && mounted;
  }

  /// Explains matching the unnamed faces, then runs it on a yes. A retry
  /// after a failure goes straight to [_recognize]: it has been answered.
  Future<void> _askRecognize() async {
    final l10n = AppLocalizations.of(context);
    if (await _confirm(
      title: l10n.peopleRecognize,
      message: l10n.peopleRecognizeConfirm,
      action: l10n.peopleRecognizeRun,
    )) {
      await _recognize();
    }
  }

  /// Explains the review list, then opens it on a yes.
  Future<void> _askReview() async {
    final l10n = AppLocalizations.of(context);
    if (await _confirm(
      title: l10n.reviewTitle,
      message: l10n.reviewConfirm,
      action: l10n.reviewOpen,
    )) {
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const ReviewScreen()));
    }
  }

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.peopleRecognized(filed))));
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
    final l10n = AppLocalizations.of(context);
    final faces = ref.watch(faceGroupsProvider);
    final query = _query.text.trim();

    // Back closes the name field before it leaves the tab.
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stopSearching();
      },
      child: Scaffold(
        body: RefreshIndicator(
          // Awaited, as on the timeline: invalidating alone ends the spinner
          // before the new answer is in.
          onRefresh: () => ref.refresh(faceGroupsProvider.future),
          child: LoadMoreOnScroll(
            // Not while a name is typed: every named person comes with the
            // first pages (see _throughTheNamed), and the unnamed further down
            // have no name to match.
            hasMore: query.isEmpty && (faces.valueOrNull?.hasMore ?? false),
            onLoadMore: () => ref.read(faceGroupsProvider.notifier).loadMore(),
            child: ScrollableView(
              // See the note in timeline_screen.dart: a short list would otherwise
              // refuse the pull-to-refresh gesture.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                  title: _searching
                      ? TextField(
                          controller: _query,
                          // Opened by a tap on the magnifier, so typing is next.
                          autofocus: true,
                          autocorrect: false,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: l10n.personFilterHint,
                            border: InputBorder.none,
                          ),
                          onChanged: (_) => setState(() {}),
                        )
                      : Text(l10n.navPeople),
                  floating: true,
                  snap: true,
                  actions: [
                    if (_searching)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
                        onPressed: _stopSearching,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: l10n.personFilterHint,
                        onPressed: () => setState(() => _searching = true),
                      ),
                    // The name field gets the room while it is open.
                    if (!_searching) ...[
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
                          tooltip: l10n.peopleRecognize,
                          onPressed: _askRecognize,
                        ),
                      if (ref.watch(
                        hasCapabilityProvider(Capability.faceVerification),
                      ))
                        IconButton(
                          icon: const Icon(Icons.rate_review_outlined),
                          tooltip: l10n.reviewTitle,
                          onPressed: _askReview,
                        ),
                    ],
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
                  data: (data) {
                    final shown = [
                      for (final g in data.groups)
                        if (personMatches(g, query)) g,
                    ];
                    return [
                      if (data.groups.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyMessage(
                            message: l10n.peopleEmpty,
                            icon: Icons.person_outline,
                          ),
                        )
                      else if (shown.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyMessage(
                            message: l10n.personFilterNoMatch,
                            icon: Icons.search_off,
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: FaceSliverGrid(
                            faceGroups: orderedFaceGroups(
                              shown,
                              ref.watch(peopleOrderProvider).valueOrNull ??
                                  PeopleOrder.nameAscending,
                              unnamedFewestFirst: data.fewestFirst,
                            ),
                          ),
                        ),
                      if (data.loadingMore && query.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ),
                    ];
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
