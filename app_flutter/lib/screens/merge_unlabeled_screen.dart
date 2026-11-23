import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/auth.dart';
import '../state/library.dart';
import '../state/search_limit.dart' show settingsStoreProvider;
import '../widgets/action_failure.dart';
import '../widgets/async_states.dart';
import '../widgets/face_grid.dart';
import '../widgets/face_move.dart';
import '../widgets/fullscreen_gallery.dart';

/// The server's proposals to join unnamed people whose faces look alike, as
/// rows of faces to accept one by one, all at once, or turn down.
///
/// Opening it changes nothing: the proposals come from a dry run. A face can
/// be tapped to leave its group out of a proposal, and held to see its
/// photo. Turned-down proposals are remembered on this device for this
/// account and stay hidden until shown again.
///
/// Only groups without a name and without a confirmed face take part — the
/// server's rule. Merging goes through `combineFaceGroups`, so it does what
/// was shown and nothing else; see [FaceActions.mergeAll].
class MergeUnlabeledScreen extends ConsumerStatefulWidget {
  const MergeUnlabeledScreen({super.key});

  @override
  ConsumerState<MergeUnlabeledScreen> createState() =>
      _MergeUnlabeledScreenState();
}

class _MergeUnlabeledScreenState extends ConsumerState<MergeUnlabeledScreen> {
  /// Every proposal of the last dry run not yet merged; null while it runs.
  List<MergeProposal>? _proposals;
  Object? _error;

  /// Signatures of the proposals turned down on this account.
  Set<String> _rejected = {};

  /// Per proposal signature, the groups the user left out of it.
  final _excluded = <String, Set<String>>{};

  /// The proposal being merged, while it is.
  String? _merging;

  /// How far merging all of them has got, while it runs.
  ({int done, int total})? _bulk;

  /// The account the proposals came from: every group id in them is its.
  String? _owner;

  bool get _busy => _merging != null || _bulk != null;

  @override
  void initState() {
    super.initState();
    // Not through [_load]: its setState is not allowed before the first
    // build, and there is nothing to clear yet.
    _fetch();
  }

  /// Runs the dry run again, from a clean slate: groups have changed.
  Future<void> _load() async {
    setState(() {
      _proposals = null;
      _error = null;
      _excluded.clear();
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    // Waited for rather than read: opened while the sign-in is still being
    // read back, the account would be none, and the proposals and their
    // turned-down list would belong to nobody.
    final owner = (await ref.read(authProvider.future))?.serverId;
    if (!mounted) return;
    try {
      final rejected = owner == null
          ? <String>{}
          : await ref.read(settingsStoreProvider).rejectedMergeProposals(owner);
      final proposals = await ref.read(faceActionsProvider).mergeProposals();
      if (!mounted) return;
      setState(() {
        _owner = owner;
        _rejected = rejected;
        _proposals = proposals;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  List<MergeProposal> get _shown => [
    for (final p in _proposals ?? const <MergeProposal>[])
      if (!_rejected.contains(p.signature)) p,
  ];

  Set<String> _kept(MergeProposal proposal) {
    final out = _excluded[proposal.signature] ?? const {};
    return {
      for (final id in proposal.groupIds)
        if (!out.contains(id)) id,
    };
  }

  void _toggle(MergeProposal proposal, String groupId) => setState(() {
    final out = _excluded.putIfAbsent(proposal.signature, () => {});
    if (!out.remove(groupId)) out.add(groupId);
  });

  void _say(String text) => ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Writes the turned-down proposals. A failure only costs the memory of
  /// them on the next visit, so it is reported but changes nothing here.
  Future<void> _storeRejected() async {
    final owner = _owner;
    if (owner == null) return;
    try {
      await ref
          .read(settingsStoreProvider)
          .setRejectedMergeProposals(owner, _rejected);
    } catch (_) {
      if (mounted) _say(AppLocalizations.of(context).mergeUnlabeledNotStored);
    }
  }

  void _reject(MergeProposal proposal) {
    setState(() => _rejected = {..._rejected, proposal.signature});
    _storeRejected();
  }

  void _showHidden() {
    setState(() => _rejected = {});
    _storeRejected();
  }

  Future<void> _mergeOne(MergeProposal proposal) async {
    final merge = proposal.mergeOf(_kept(proposal));
    if (merge != null) await _merge(proposal, merge);
  }

  /// Asks who the proposal is — somebody new, named on the spot, or somebody
  /// there is — and merges it as them.
  ///
  /// Without a name the merged group is one more unnamed person among
  /// thousands, and finding it again to name it means searching for it.
  /// Into somebody there is, the kept groups go straight into them, which is
  /// often what a proposal turns out to be: more photos of a known person.
  Future<void> _askName(MergeProposal proposal) async {
    final kept = _kept(proposal);
    final merge = proposal.mergeOf(kept);
    if (merge == null) return;
    final l10n = AppLocalizations.of(context);

    final target = await showDialog<FaceMoveTarget>(
      context: context,
      builder: (context) => PickPersonDialog(
        exclude: proposal.destinationId,
        title: l10n.galleryFaceAssignPick,
        offerNewAndUnlabeled: true,
        offerUnlabeled: false,
      ),
    );
    if (target == null || !mounted) return;

    switch (target) {
      case MoveToNewPerson(name: final typed):
        final name = (await showDialog<String>(
          context: context,
          builder: (context) =>
              PersonNameDialog(initial: null, suggestion: typed),
        ))?.trim();
        if (name == null || name.isEmpty || !mounted) return;
        await _merge(proposal, merge, newName: name);

      case MoveToPerson(:final person):
        // Every kept group goes in, the proposal's destination too; the
        // person may be one of the proposal's own groups, which stays.
        final into = (
          destination: person.id,
          sources: [
            for (final id in proposal.groupIds)
              if (kept.contains(id) && id != person.id) id,
          ],
          faceIds: merge.faceIds,
        );
        await _merge(proposal, into, shownAs: describePerson(person, l10n));

      case MoveToUnlabeled() || KeepOnItsOwn():
        return;
    }
  }

  /// Merges one proposal as [merge], then names the result [newName] if
  /// given. Says what came of it: merged, or merged as somebody.
  ///
  /// The faces are flagged for review either way (see
  /// [FaceActions.mergeAll]). A failure of that, or of the naming, comes
  /// after the merge went through, and each offers to retry only itself.
  Future<void> _merge(
    MergeProposal proposal,
    ProposalMerge merge, {
    String? newName,
    String? shownAs,
  }) async {
    final l10n = AppLocalizations.of(context);
    final owner = _owner;

    setState(() => _merging = proposal.signature);
    try {
      ensureStillSignedIn(ref, owner);
      ReviewNotFlaggedException? notFlagged;
      try {
        await ref
            .read(faceActionsProvider)
            .mergeAll(
              [merge],
              onDone: (_) {
                if (mounted) {
                  setState(
                    () => _proposals = [..._proposals!]..remove(proposal),
                  );
                }
              },
            );
      } on ReviewNotFlaggedException catch (error) {
        notFlagged = error;
      }
      if (!mounted) return;

      if (newName != null) {
        await _name(merge.destination, newName, owner);
      } else {
        _say(
          shownAs == null
              ? l10n.mergeUnlabeledMerged
              : l10n.mergeUnlabeledMergedAs(shownAs),
        );
      }
      if (notFlagged != null && mounted) await _reportNotFlagged(notFlagged);
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.mergeUnlabeledFailed,
          retry: () =>
              _merge(proposal, merge, newName: newName, shownAs: shownAs),
        );
      }
    } finally {
      if (mounted) setState(() => _merging = null);
    }
  }

  /// Names the merged group [groupId]. Its own step with its own retry: the
  /// merge has gone through, and merging again is not possible.
  Future<void> _name(String groupId, String name, String? owner) async {
    final l10n = AppLocalizations.of(context);
    try {
      ensureStillSignedIn(ref, owner);
      final stored = await ref.read(faceActionsProvider).rename(groupId, name);
      if (mounted) _say(l10n.mergeUnlabeledMergedAs(stored ?? name));
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personFacesNameFailed,
          retry: () => _name(groupId, name, owner),
          retryAnyError: true,
        );
      }
    }
  }

  Future<void> _askMergeAll() async {
    final l10n = AppLocalizations.of(context);
    final pending = [
      for (final p in _shown)
        if (p.mergeOf(_kept(p)) != null) p,
    ];
    if (pending.isEmpty) return;

    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mergeUnlabeledAcceptAll(pending.length)),
        content: Text(l10n.mergeUnlabeledAcceptAllConfirm(pending.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.mergeUnlabeledMerge),
          ),
        ],
      ),
    );
    if (yes == true && mounted) await _mergeAll(pending);
  }

  /// Merges [pending] as shown — the groups left out stay out — and drops
  /// each from the list as it goes through, so a failure halfway leaves the
  /// rest on screen to try again.
  Future<void> _mergeAll(List<MergeProposal> pending) async {
    final l10n = AppLocalizations.of(context);
    final merges = [for (final p in pending) p.mergeOf(_kept(p))!];

    setState(() => _bulk = (done: 0, total: merges.length));
    var done = 0;
    try {
      ensureStillSignedIn(ref, _owner);
      await ref
          .read(faceActionsProvider)
          .mergeAll(
            merges,
            onDone: (count) {
              done = count;
              if (!mounted) return;
              setState(() {
                _bulk = (done: count, total: merges.length);
                _proposals = [..._proposals!]..remove(pending[count - 1]);
              });
            },
          );
      if (mounted) _say(l10n.mergeUnlabeledAllMerged(done));
    } on ReviewNotFlaggedException catch (error) {
      if (mounted) await _reportNotFlagged(error);
    } catch (error) {
      if (mounted) {
        final rest = pending.skip(done).toList();
        await showActionFailure(
          context,
          ref,
          error: error,
          message: done == 0
              ? l10n.mergeUnlabeledFailed
              : (e) => l10n.mergeUnlabeledPartlyFailed(done, e),
          retry: () => _mergeAll(rest),
          // For any failure: carrying on with the rest is what a retry is
          // for here, whatever stopped it.
          retryAnyError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _bulk = null);
    }
  }

  /// The merges went through, the flagging for review did not: says so, and
  /// a retry sends only the flagging again.
  Future<void> _reportNotFlagged(ReviewNotFlaggedException failure) async {
    final l10n = AppLocalizations.of(context);
    final owner = _owner;
    await showActionFailure(
      context,
      ref,
      error: failure.cause,
      message: l10n.mergeUnlabeledNotFlagged,
      retry: () async {
        try {
          ensureStillSignedIn(ref, owner);
          await ref.read(faceActionsProvider).flagForReview(failure.faceIds);
        } catch (error) {
          if (mounted) {
            await _reportNotFlagged(
              ReviewNotFlaggedException(failure.faceIds, error),
            );
          }
        }
      },
      retryAnyError: true,
    );
  }

  void _openPhoto(MergeFace face) => showFullscreenGallery(
    context,
    media: [
      MediaItem(
        id: face.mediaId,
        type: MediaType.photo,
        thumbnail: face.thumbnail,
      ),
    ],
    initialIndex: 0,
    showFaces: true,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final proposals = _proposals;
    final shown = _shown;
    final hidden = (proposals?.length ?? 0) - shown.length;
    final bulk = _bulk;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mergeUnlabeledTitle),
        actions: [
          if (proposals != null && !_busy)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.mergeUnlabeledSearchAgain,
              onPressed: _load,
            ),
        ],
      ),
      bottomNavigationBar: shown.length < 2 || proposals == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: bulk == null
                      ? const Icon(Icons.done_all)
                      : const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                  label: Text(
                    bulk == null
                        ? l10n.mergeUnlabeledAcceptAll(shown.length)
                        : l10n.mergeUnlabeledProgress(bulk.done, bulk.total),
                  ),
                  onPressed: _busy ? null : _askMergeAll,
                ),
              ),
            ),
      body: _body(context, l10n, proposals, shown, hidden),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    List<MergeProposal>? proposals,
    List<MergeProposal> shown,
    int hidden,
  ) {
    final error = _error;
    if (error != null) {
      return ErrorMessage.forError(error, onRetry: _load);
    }
    if (proposals == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.mergeUnlabeledSearching),
          ],
        ),
      );
    }

    final hiddenBanner = hidden > 0
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Expanded(child: Text(l10n.mergeUnlabeledHidden(hidden))),
                TextButton(
                  onPressed: _busy ? null : _showHidden,
                  child: Text(l10n.mergeUnlabeledShowHidden),
                ),
              ],
            ),
          )
        : null;

    if (shown.isEmpty) {
      return ListView(
        children: [
          ?hiddenBanner,
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                EmptyMessage(
                  message: proposals.isEmpty && hidden == 0
                      ? l10n.mergeUnlabeledNone
                      : l10n.mergeUnlabeledAllDone,
                  icon: Icons.task_alt,
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.mergeUnlabeledSearchAgain),
                  onPressed: _load,
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: shown.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?hiddenBanner,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(l10n.mergeUnlabeledHint),
              ),
            ],
          );
        }
        final proposal = shown[index - 1];
        return _ProposalCard(
          proposal: proposal,
          kept: _kept(proposal),
          merging: _merging == proposal.signature,
          enabled: !_busy,
          onToggle: (groupId) => _toggle(proposal, groupId),
          onOpen: _openPhoto,
          onMerge: () => _mergeOne(proposal),
          onReject: () => _reject(proposal),
          onName: () => _askName(proposal),
        );
      },
    );
  }
}

/// One proposal: its faces, grouped by the group they are in now, and what
/// to do with it.
class _ProposalCard extends StatelessWidget {
  final MergeProposal proposal;

  /// The groups still in it; the others are drawn faded and crossed out.
  final Set<String> kept;

  final bool merging;
  final bool enabled;
  final void Function(String groupId) onToggle;
  final void Function(MergeFace face) onOpen;
  final VoidCallback onMerge;
  final VoidCallback onReject;

  /// Merges it as somebody: a new person named on the spot, or one there is.
  final VoidCallback onName;

  const _ProposalCard({
    required this.proposal,
    required this.kept,
    required this.merging,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
    required this.onMerge,
    required this.onReject,
    required this.onName,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canMerge = proposal.mergeOf(kept) != null;
    final keptFaces = proposal.faces.where((f) => kept.contains(f.groupId));
    // The faces of one group side by side, the groups in the proposal's
    // order: tapping one leaves all of them out, so they belong together.
    final order = proposal.groupIds;
    final faces = [...proposal.faces]
      ..sort((a, b) {
        final byGroup = order
            .indexOf(a.groupId)
            .compareTo(order.indexOf(b.groupId));
        return byGroup != 0 ? byGroup : a.id.compareTo(b.id);
      });

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.mergeUnlabeledProposal(keptFaces.length),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final face in faces)
                  _FaceChoice(
                    face: face,
                    included: kept.contains(face.groupId),
                    onTap: enabled ? () => onToggle(face.groupId) : null,
                    onLongPress: () => onOpen(face),
                  ),
              ],
            ),
            if (!canMerge) ...[
              const SizedBox(height: 8),
              Text(
                l10n.mergeUnlabeledNotEnough,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 4),
            // A Wrap, not a Row: three buttons in German or Danish do not
            // fit one line of a phone held upright.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: enabled ? onReject : null,
                  child: Text(l10n.mergeUnlabeledReject),
                ),
                OutlinedButton(
                  onPressed: enabled && canMerge ? onName : null,
                  child: Text(l10n.mergeUnlabeledName),
                ),
                FilledButton(
                  onPressed: enabled && canMerge ? onMerge : null,
                  child: merging
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.mergeUnlabeledMerge),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One face of a proposal, faded and crossed out once its group is left out.
class _FaceChoice extends StatelessWidget {
  final MergeFace face;
  final bool included;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  const _FaceChoice({
    required this.face,
    required this.included,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      selected: included,
      button: true,
      label: included ? l10n.mergeUnlabeledFaceIn : l10n.mergeUnlabeledFaceOut,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: included ? 1 : 0.3,
              child: FaceThumbnail(face: face.asThumbnail, size: 64),
            ),
            if (!included)
              Icon(
                Icons.close,
                size: 36,
                color: Theme.of(context).colorScheme.error,
              ),
          ],
        ),
      ),
    );
  }
}
