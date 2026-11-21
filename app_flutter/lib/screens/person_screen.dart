import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../widgets/action_failure.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/face_move.dart';
import '../widgets/media_grid.dart';

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
  }) async {
    setState(() => _busy = true);
    try {
      final done = await action();

      if (!mounted) return;
      _clearSelection();
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(done)));
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: failed,
          retry: retry,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final photos = ref.watch(personPhotosProvider(widget.faceGroup.id));
    final loaded = photos.valueOrNull ?? const <PersonPhoto>[];
    final picking = _selected.isNotEmpty;

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
                          onPressed: () => setState(() {
                            _selected
                              ..clear()
                              ..addAll([
                                for (final photo in loaded) photo.media.id,
                              ]);
                          }),
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
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      sliver: MediaSliverGrid(
                        media: [for (final photo in data) photo.media],
                        selection: MediaSelection(
                          selected: _selected,
                          onToggle: _toggle,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
        ),
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
