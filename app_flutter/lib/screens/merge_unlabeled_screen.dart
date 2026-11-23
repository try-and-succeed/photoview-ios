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
import '../widgets/face_move.dart' show ensureStillSignedIn;
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
    if (merge == null) return;
    final l10n = AppLocalizations.of(context);

    setState(() => _merging = proposal.signature);
    try {
      ensureStillSignedIn(ref, _owner);
      await ref
          .read(faceActionsProvider)
          .merge(merge.destination, merge.sources);
      if (!mounted) return;
      setState(() => _proposals = [..._proposals!]..remove(proposal));
      _say(l10n.mergeUnlabeledMerged);
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.mergeUnlabeledFailed,
          retry: () => _mergeOne(proposal),
        );
      }
    } finally {
      if (mounted) setState(() => _merging = null);
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

  const _ProposalCard({
    required this.proposal,
    required this.kept,
    required this.merging,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
    required this.onMerge,
    required this.onReject,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: enabled ? onReject : null,
                  child: Text(l10n.mergeUnlabeledReject),
                ),
                const SizedBox(width: 8),
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
