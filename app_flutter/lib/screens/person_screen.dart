import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/capabilities.dart';
import '../state/library.dart';
import '../widgets/action_failure.dart';
import '../widgets/reclassify_preview.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/face_move.dart';
import '../widgets/media_grid.dart';
import 'review_screen.dart';

/// Which of a person's photos are shown.
enum PersonPhotoFilter {
  all,

  /// Every face of this person on the photo has been confirmed.
  verified,

  /// At least one of them has not.
  unverified,

  /// At least one of them waits for review after an automatic run.
  review,

  /// More than one face on the photo is filed under this person. Often one
  /// of them is someone else, but not always: a sheet of passport photos, a
  /// mirror or a photo of a photo really shows one person several times.
  /// The filter only finds them; whether they are right is the user's call.
  twice;

  bool keeps(PersonPhoto photo) => switch (this) {
    all => true,
    verified => photo.verified,
    unverified => !photo.verified,
    review => photo.needsReview,
    twice => photo.faceIds.length > 1,
  };
}

class PersonScreen extends ConsumerStatefulWidget {
  final FaceGroup faceGroup;

  const PersonScreen({super.key, required this.faceGroup});

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends ConsumerState<PersonScreen> {
  /// Held here rather than read from [PersonScreen.faceGroup] so a rename
  /// shows in the title at once. The group was handed over by the grid and is
  /// not refetched while this screen is open.
  late String? _label = widget.faceGroup.label;

  bool _busy = false;

  Future<void> _rename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => PersonNameDialog(initial: _label),
    );

    // Null is "cancelled"; an empty string is "remove the name", which the
    // server takes as a null label.
    if (name == null || !mounted) return;

    await _store(name.trim().isEmpty ? null : name.trim());
  }

  /// Sends one already-chosen name to the server.
  ///
  /// Separate from asking for it so that a retry repeats the sending alone. A
  /// retry that started over at the dialog would make the user type a name
  /// they have just typed, having answered a question about a certificate
  /// they did not expect either.
  Future<void> _store(String? label) async {
    final l10n = AppLocalizations.of(context);

    setState(() => _busy = true);
    try {
      final stored = await ref
          .read(faceActionsProvider)
          .rename(widget.faceGroup.id, label);
      if (mounted) setState(() => _label = stored);
    } catch (error) {
      if (mounted) {
        // Renaming is the one thing on this screen that writes to the server,
        // so it is the one that discovers a certificate reissued overnight.
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personNameFailed,
          retry: () => _store(label),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Folds another person into this one.
  ///
  /// This one is the destination, so the user stays where they are and the
  /// picked person is the one that disappears — which is also the server's
  /// only way of getting rid of a face group at all.
  Future<void> _merge() async {
    final picked = await showDialog<FaceMoveTarget>(
      context: context,
      builder: (context) => PickPersonDialog(
        exclude: widget.faceGroup.id,
        title: AppLocalizations.of(context).personMergePick,
      ),
    );
    if (picked is! MoveToPerson || !mounted) return;

    await _sendMerge(picked.person);
  }

  /// Sends one already-picked person, so a retry repeats the sending alone —
  /// the same rule as [_store] and [_sendMove].
  Future<void> _sendMerge(FaceGroup other) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);

    try {
      final label = await ref.read(faceActionsProvider).merge(
        widget.faceGroup.id,
        [other.id],
      );

      if (!mounted) return;
      setState(() => _label = label);

      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.personMerged(describePerson(other, l10n))),
          ),
        );
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personMergeFailed,
          retry: () => _sendMerge(other),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ticked photos, by media id. Empty means nobody is picking — as in the
  /// album, there is no separate flag.
  final Set<String> _selected = {};

  void _toggle(MediaItem item) => setState(() {
    if (!_selected.remove(item.id)) _selected.add(item.id);
  });

  void _clearSelection() => setState(_selected.clear);

  /// The `imageFace` ids behind the ticked photos.
  ///
  /// A photo the detector found this person in twice contributes both of its
  /// faces: the tile stands for "this photo's faces in this group", and
  /// leaving one behind would file half a photo under someone else.
  List<String> _tickedFaceIds(List<PersonPhoto> photos) => [
    for (final photo in photos)
      if (_selected.contains(photo.media.id)) ...photo.faceIds,
  ];

  /// Files the ticked photos under somebody else, a new person, or nobody.
  ///
  /// The other direction from merging: there the whole person moves, here the
  /// few photos that were never this person in the first place.
  Future<void> _moveSelection(List<PersonPhoto> photos) => _mover().pickAndMove(
    context,
    ref,
    faceIds: _tickedFaceIds(photos),
    count: _tickedCount(photos),
    title: AppLocalizations.of(context).personFacesMovePick,
  );

  /// Lifts the ticked photos out into a person of their own.
  ///
  /// Also the way back out of a merge that was wrong — the server has no undo
  /// for one, and no way to delete a person either.
  Future<void> _detachSelection(List<PersonPhoto> photos) =>
      _mover().askAndDetach(
        context,
        ref,
        faceIds: _tickedFaceIds(photos),
        count: _tickedCount(photos),
      );

  /// Confirms this person's faces on the ticked photos — or, when all of
  /// them are confirmed already, takes that back.
  ///
  /// Only this person's faces: the others on the same photos are other
  /// people's business, and confirming them unseen would be a guess. Nothing
  /// moves, so nothing is asked first.
  Future<void> _verifySelection(List<PersonPhoto> photos, bool verified) {
    final faceIds = _tickedFaceIds(photos);
    final count = _tickedCount(photos);
    final owner = signedInAccount(ref);
    return _sendVerify(faceIds, count, verified, owner);
  }

  /// The ids as they were when the action was asked for, so a retry sends
  /// the same — see [_store].
  Future<void> _sendVerify(
    List<String> faceIds,
    int count,
    bool verified,
    String? owner,
  ) {
    final l10n = AppLocalizations.of(context);
    return _run(
      () async {
        ensureStillSignedIn(ref, owner);
        await ref
            .read(faceActionsProvider)
            .verifyFaces(faceIds, verified: verified);
        return verified
            ? l10n.personFacesVerified(count)
            : l10n.personFacesUnverified(count);
      },
      failed: l10n.personFacesVerifyFailed,
      retry: () => _sendVerify(faceIds, count, verified, owner),
    );
  }

  /// Files this person's unconfirmed faces again, comparing them with the
  /// confirmed faces of everybody.
  ///
  /// Asked in two steps: the server first says what it would do, and only a
  /// yes to that sends the real thing — faces leave this person in numbers,
  /// and the server has no undo.
  Future<void> _reclassify() async {
    final l10n = AppLocalizations.of(context);
    final name = _label ?? l10n.personUnlabeled;
    final owner = signedInAccount(ref);

    final ReclassifyResult preview;
    setState(() => _busy = true);
    try {
      ensureStillSignedIn(ref, owner);
      preview = await ref
          .read(faceActionsProvider)
          .reclassify(widget.faceGroup.id, dryRun: true);
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personReclassifyFailed,
          retry: _reclassify,
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    if (preview.checked == 0) {
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.personReclassifyNothing)));
      return;
    }

    final yes = await showDialog<bool>(
      context: context,
      builder: (context) =>
          ReclassifyPreviewDialog(result: preview, name: name),
    );
    if (yes != true || !mounted) return;

    await _sendReclassify(owner);
  }

  /// The real run, after the user has seen the preview and said yes. A retry
  /// repeats only this — the preview has been seen and answered.
  Future<void> _sendReclassify(String? owner) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    setState(() => _busy = true);
    try {
      ensureStillSignedIn(ref, owner);
      final done = await ref
          .read(faceActionsProvider)
          .reclassify(widget.faceGroup.id, dryRun: false);

      // The messenger outlives this screen, and so does the way to the
      // review list: the faces that left this person are reviewed there.
      messenger
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.personReclassifyDone(done.checked)),
            action: SnackBarAction(
              label: l10n.reviewOpen,
              onPressed: () => navigator.push(
                MaterialPageRoute<void>(builder: (_) => const ReviewScreen()),
              ),
            ),
          ),
        );
    } catch (error) {
      if (!mounted) {
        messenger
          ..removeCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.personReclassifyFailed(describeError(error, l10n)),
              ),
            ),
          );
      } else {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personReclassifyFailed,
          retry: () => _sendReclassify(owner),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Which photos are shown. Only offered on a server that knows which faces
  /// are confirmed; elsewhere it stays at all.
  PersonPhotoFilter _filter = PersonPhotoFilter.all;

  void _setFilter(PersonPhotoFilter filter) => setState(() {
    _filter = filter;
    // A tick on a photo that is no longer shown would travel unseen with
    // the next action.
    _selected.clear();
  });

  /// How many photos are ticked — what the user counts, as opposed to the
  /// faces behind them, of which a photo may have two.
  int _tickedCount(List<PersonPhoto> photos) =>
      photos.where((photo) => _selected.contains(photo.media.id)).length;

  FaceMove _mover() => FaceMove(
    from: _label ?? AppLocalizations.of(context).personUnlabeled,
    exclude: widget.faceGroup.id,
    run: _run,
  );

  /// Runs one face action: spinner, message, and out of the picking mode.
  ///
  /// The three are the same either way, and the picking mode has to end on
  /// success — the photos it was holding are no longer this person's.
  Future<void> _run(
    Future<String> Function() action, {
    required String Function(String error) failed,
    required Future<void> Function() retry,
    bool retryAnyError = false,
  }) async {
    // Taken now: the messenger sits above this screen and outlives it, so
    // the answer still arrives when the screen was left while the request
    // ran — after a move that went half through, it is the only word on
    // where the photos are.
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    void say(String text) => messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

    setState(() => _busy = true);
    try {
      final done = await action();

      if (mounted) _clearSelection();
      say(done);
    } catch (error) {
      if (!mounted) {
        // No certificate to review and nothing to retry from without the
        // screen — but still the message.
        say(failed(describeError(error, l10n)));
      } else {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: failed,
          retry: retry,
          retryAnyError: retryAnyError,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Ticks only what is still here. A move that went half through — the
    // faces out, the naming failed — leaves the picking mode on, and the
    // photos it held vanish with the next fetch: still counted, they kept
    // "3 selected" on screen with nothing behind it, and Back only ended
    // the picking.
    ref.listen(personPhotosProvider(widget.faceGroup.id), (_, next) {
      final present = {
        for (final photo in next.valueOrNull ?? const <PersonPhoto>[])
          photo.media.id,
      };
      if (next.hasValue && _selected.any((id) => !present.contains(id))) {
        setState(() => _selected.retainAll(present));
      }
    });
    final photos = ref.watch(personPhotosProvider(widget.faceGroup.id));
    final withStatus = ref.watch(
      hasCapabilityProvider(Capability.faceVerification),
    );
    final filter = withStatus ? _filter : PersonPhotoFilter.all;
    final loaded = photos.valueOrNull ?? const <PersonPhoto>[];
    final shown = [
      for (final photo in loaded)
        if (filter.keeps(photo)) photo,
    ];
    final picking = _selected.isNotEmpty;
    final allTickedVerified = loaded
        .where((photo) => _selected.contains(photo.media.id))
        .every((photo) => photo.verified);

    return PopScope(
      // Back leaves the picking mode, not the person — as in the album, for
      // the same reason: a selection is easy to lose and tedious to redo.
      canPop: !picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: picking
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.selectionCancel,
                  onPressed: _clearSelection,
                ),
                title: Text(l10n.selectionCount(_selected.length)),
                actions: _busy
                    ? const [_BusyIndicator()]
                    : [
                        IconButton(
                          icon: const Icon(Icons.select_all),
                          tooltip: l10n.selectionAll,
                          // What is shown: with a filter on, "all" means all
                          // of those, not the photos the filter hides.
                          onPressed: () => setState(() {
                            _selected
                              ..clear()
                              ..addAll([
                                for (final photo in shown) photo.media.id,
                              ]);
                          }),
                        ),
                        if (withStatus)
                          IconButton(
                            icon: Icon(
                              allTickedVerified
                                  ? Icons.remove_done
                                  : Icons.verified_outlined,
                            ),
                            tooltip: allTickedVerified
                                ? l10n.personFacesUnverify
                                : l10n.personFacesVerify,
                            onPressed: () =>
                                _verifySelection(loaded, !allTickedVerified),
                          ),
                        IconButton(
                          icon: const Icon(Icons.person_add_alt),
                          tooltip: l10n.personFacesMove,
                          onPressed: () => _moveSelection(loaded),
                        ),
                        IconButton(
                          icon: const Icon(Icons.call_split),
                          tooltip: l10n.personFacesDetach,
                          onPressed: () => _detachSelection(loaded),
                        ),
                      ],
              )
            : AppBar(
                title: Text(_label ?? l10n.personUnlabeled),
                actions: [
                  if (_busy)
                    const _BusyIndicator()
                  else ...[
                    const MediaLayoutButton(),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.personName,
                      onPressed: _rename,
                    ),
                    IconButton(
                      icon: const Icon(Icons.merge_type),
                      tooltip: l10n.personMerge,
                      onPressed: _merge,
                    ),
                    if (withStatus)
                      IconButton(
                        icon: const Icon(Icons.auto_fix_high),
                        tooltip: l10n.personReclassify,
                        onPressed: _reclassify,
                      ),
                  ],
                ],
              ),
        body: photos.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorMessage.forError(
            error,
            onRetry: () =>
                ref.invalidate(personPhotosProvider(widget.faceGroup.id)),
          ),
          data: (data) => data.isEmpty
              ? EmptyMessage(message: l10n.personEmpty)
              : ScrollableView(
                  slivers: [
                    if (withStatus)
                      SliverToBoxAdapter(
                        child: _FilterBar(
                          photos: data,
                          selected: filter,
                          onSelected: _setFilter,
                        ),
                      ),
                    if (shown.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyMessage(message: l10n.personFilterEmpty),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        sliver: _grid(shown, withStatus, filter, l10n),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
        ),
      ),
    );
  }
}

extension on _PersonScreenState {
  /// The photos, each marked when its faces are confirmed or wait for
  /// review.
  ///
  /// Opened from the unconfirmed or the review filter, the gallery frames
  /// the faces at once: those photos are opened to be checked.
  Widget _grid(
    List<PersonPhoto> shown,
    bool withStatus,
    PersonPhotoFilter filter,
    AppLocalizations l10n,
  ) {
    final byId = {for (final photo in shown) photo.media.id: photo};

    return MediaSliverGrid(
      media: [for (final photo in shown) photo.media],
      selection: MediaSelection(selected: _selected, onToggle: _toggle),
      showFacesInGallery:
          filter == PersonPhotoFilter.unverified ||
          filter == PersonPhotoFilter.review ||
          filter == PersonPhotoFilter.twice,
      // A person's photos come from everywhere; the album says when and
      // where a photo belongs, and holds the photos around it.
      albumLinkInGallery: true,
      badgeFor: withStatus
          ? (item) {
              final photo = byId[item.id];
              if (photo == null) return null;
              if (photo.verified) {
                return MediaTileBadge(
                  icon: Icons.verified,
                  color: Colors.lightGreenAccent,
                  label: l10n.personFilterVerified,
                );
              }
              if (photo.needsReview) {
                return MediaTileBadge(
                  icon: Icons.rate_review,
                  color: Colors.amberAccent,
                  label: l10n.personFilterReview,
                );
              }
              return null;
            }
          : null,
    );
  }
}

/// The filters over a person's photos, each with how many photos it holds.
class _FilterBar extends StatelessWidget {
  final List<PersonPhoto> photos;
  final PersonPhotoFilter selected;
  final ValueChanged<PersonPhotoFilter> onSelected;

  const _FilterBar({
    required this.photos,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String name(PersonPhotoFilter filter) => switch (filter) {
      PersonPhotoFilter.all => l10n.personFilterAll,
      PersonPhotoFilter.verified => l10n.personFilterVerified,
      PersonPhotoFilter.unverified => l10n.personFilterUnverified,
      PersonPhotoFilter.review => l10n.personFilterReview,
      PersonPhotoFilter.twice => l10n.personFilterTwice,
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          for (final filter in PersonPhotoFilter.values)
            // Most people are never on a photo twice; for them the chip would
            // only ever say zero. Kept while chosen, so the choice stays
            // visible once the last such photo is cleared up.
            if (filter != PersonPhotoFilter.twice ||
                filter == selected ||
                photos.any(filter.keeps))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  // The number before the word, as on the people's tiles: cut
                  // short, it is the word that goes. Unlike there, a zero is
                  // shown — it is a count here, and the answer to the filter.
                  label: Text(
                    '${NumberFormat.decimalPattern().format(photos.where(filter.keeps).length)}'
                    ' · ${name(filter)}',
                  ),
                  selected: filter == selected,
                  onSelected: (_) => onSelected(filter),
                ),
              ),
        ],
      ),
    );
  }
}

/// The spinner that stands where the actions do while one is running.
class _BusyIndicator extends StatelessWidget {
  const _BusyIndicator();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16),
    child: Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}
