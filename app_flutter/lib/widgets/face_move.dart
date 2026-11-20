import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../state/people_order.dart';
import 'async_states.dart';
import 'face_grid.dart';
import 'load_more.dart';

/// Runs one face action and reports how it went.
///
/// Supplied by the screen, which knows what goes with an action there — a
/// spinner and a selection to end on the person screen, nothing of the kind in
/// the gallery. [action] returns the sentence to show when it worked.
typedef FaceActionRunner = Future<void> Function(
  Future<String> Function() action, {
  // The same shape `showActionFailure` wants: the server's own words go in
  // where the message says they belong.
  required String Function(String error) failed,
  required Future<void> Function() retry,
});

/// Moving faces from one person to another, the way every screen does it:
/// pick where to, name a new person if that is where, ask, then send.
///
/// The person screen moves the faces behind ticked photos; the gallery moves
/// the one face that was tapped. Both ask the same questions, in words,
/// before anything is sent: the icons alone do not say what they do.
class FaceMove {
  /// Who the faces are moved away from, as the questions name them.
  final String from;

  /// The group the faces are in now, which is no destination.
  final String exclude;

  final FaceActionRunner run;

  const FaceMove({
    required this.from,
    required this.exclude,
    required this.run,
  });

  /// Asks where [faceIds] go and sends them there.
  ///
  /// [count] is what the questions count — photos on the person screen, where
  /// one photo can stand for two faces.
  Future<void> pickAndMove(
    BuildContext context,
    WidgetRef ref, {
    required List<String> faceIds,
    required int count,
    required String title,
  }) async {
    if (faceIds.isEmpty) return;

    final target = await showDialog<FaceMoveTarget>(
      context: context,
      builder: (context) => PickPersonDialog(
        exclude: exclude,
        title: title,
        offerNewAndUnlabeled: true,
      ),
    );
    if (target == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);

    switch (target) {
      case MoveToPerson(:final person):
        final to = describePerson(person, l10n);
        if (!await confirmFaceMove(
          context,
          l10n.personMoveConfirm(count, from, to),
        )) {
          return;
        }
        await _sendMove(ref, l10n, faceIds, person);

      case MoveToNewPerson():
        final name = (await showDialog<String>(
          context: context,
          builder: (context) => const PersonNameDialog(initial: null),
        ))?.trim();
        if (name == null || name.isEmpty || !context.mounted) return;
        if (!await confirmFaceMove(
          context,
          l10n.personMoveConfirm(count, from, name),
        )) {
          return;
        }
        await _sendMoveToNew(ref, l10n, faceIds, name);

      case MoveToUnlabeled():
        if (!context.mounted) return;
        await askAndDetach(context, ref, faceIds: faceIds, count: count);
    }
  }

  /// Asks, then lifts the faces out without a name — from the split button
  /// and from the unnamed entry of the move dialog alike.
  Future<void> askAndDetach(
    BuildContext context,
    WidgetRef ref, {
    required List<String> faceIds,
    required int count,
  }) async {
    if (faceIds.isEmpty) return;
    final l10n = AppLocalizations.of(context);

    if (!await confirmFaceMove(
      context,
      l10n.personMoveConfirmUnlabeled(count, from),
    )) {
      return;
    }

    await _sendDetach(ref, l10n, faceIds);
  }

  /// Sends one already-made decision, so a retry repeats the sending alone.
  ///
  /// The user has picked a person and said yes, and has then perhaps been
  /// asked about a certificate they did not expect. Sending them back to the
  /// dialog would throw that away — and the ids are the ones from the moment
  /// of the decision, not from a selection that may have changed since.
  Future<void> _sendMove(
    WidgetRef ref,
    AppLocalizations l10n,
    List<String> faceIds,
    FaceGroup person,
  ) => run(
    () async {
      await ref.read(faceActionsProvider).moveFaces(faceIds, person.id);
      return l10n.personFacesMoved(describePerson(person, l10n));
    },
    failed: l10n.personFacesMoveFailed,
    retry: () => _sendMove(ref, l10n, faceIds, person),
  );

  /// Lifts the faces out into a group of their own and names it.
  ///
  /// Two requests, and the second can fail on its own. A retry then names the
  /// group the first one made, instead of lifting the faces out a second time
  /// — they are no longer where they were, and a second split would leave an
  /// unnamed group behind with nothing to tell it apart.
  Future<void> _sendMoveToNew(
    WidgetRef ref,
    AppLocalizations l10n,
    List<String> faceIds,
    String name, {
    String? created,
  }) {
    final actions = ref.read(faceActionsProvider);
    var made = created;

    return run(
      () async {
        made ??= await actions.detachFaces(faceIds);
        final group = made;
        final stored = group == null ? null : await actions.rename(group, name);
        return l10n.personFacesMoved(stored ?? name);
      },
      failed: l10n.personFacesMoveFailed,
      retry: () => _sendMoveToNew(ref, l10n, faceIds, name, created: made),
    );
  }

  /// The ids as they were when the action was asked for — see [_sendMove].
  Future<void> _sendDetach(
    WidgetRef ref,
    AppLocalizations l10n,
    List<String> faceIds,
  ) => run(
    () async {
      await ref.read(faceActionsProvider).detachFaces(faceIds);
      return l10n.personFacesDetached;
    },
    failed: l10n.personFacesDetachFailed,
    retry: () => _sendDetach(ref, l10n, faceIds),
  );
}

/// Asks before faces move. True only for an explicit yes.
Future<bool> confirmFaceMove(BuildContext context, String question) async {
  final l10n = AppLocalizations.of(context);

  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.personMoveConfirmTitle),
      content: Text(question),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.personMoveConfirmAction),
        ),
      ],
    ),
  );

  return yes == true && context.mounted;
}

/// Asks for the name. Returns the typed name, an empty string to remove the
/// one there is, or null when the user backed out.
class PersonNameDialog extends StatefulWidget {
  final String? initial;

  const PersonNameDialog({super.key, required this.initial});

  @override
  State<PersonNameDialog> createState() => _PersonNameDialogState();
}

class _PersonNameDialogState extends State<PersonNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(l10n.personName),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: l10n.personNameField),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(l10n.actionRemove),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.actionSave)),
      ],
    );
  }
}

/// Picks a person: the one to fold into this one, or the one faces go to.
///
/// The whole list, named and unnamed alike: the two tiles that turn out to be
/// the same person are often one of each — the reason for merging in the
/// first place. Sorted the way the People tab is, so the order is the one the
/// user just came from.
class PickPersonDialog extends ConsumerWidget {
  /// The person doing the absorbing, which cannot absorb itself.
  final String exclude;

  /// What the list is being picked for — merging a whole person in, or
  /// sending a few photos across. The same list, two different questions.
  final String title;

  /// Whether "New person…" and the unnamed are offered above the people.
  /// Only for moving photos: a whole person cannot be merged into nobody.
  final bool offerNewAndUnlabeled;

  const PickPersonDialog({
    super.key,
    required this.exclude,
    required this.title,
    this.offerNewAndUnlabeled = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final people = ref.watch(faceGroupsProvider);
    final order =
        ref.watch(peopleOrderProvider).valueOrNull ?? PeopleOrder.nameAscending;

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 320,
        height: 380,
        child: Column(
          children: [
            // Above the list rather than in it, so they are there at once —
            // before the people have loaded, and however far down the user
            // scrolls.
            if (offerNewAndUnlabeled) ...[
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: Text(l10n.personMoveToNew),
                subtitle: Text(l10n.personMoveToNewHint),
                onTap: () => Navigator.of(context).pop(const MoveToNewPerson()),
              ),
              ListTile(
                leading: const Icon(Icons.person_off_outlined),
                title: Text(l10n.personUnlabeled),
                subtitle: Text(l10n.personMoveToUnlabeledHint),
                onTap: () => Navigator.of(context).pop(const MoveToUnlabeled()),
              ),
              const Divider(),
            ],
            Expanded(child: _people(context, ref, people, order, l10n)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ],
    );
  }

  Widget _people(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<FaceGroupsData> people,
    PeopleOrder order,
    AppLocalizations l10n,
  ) => people.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => ErrorMessage.forError(
      error,
      onRetry: () => ref.invalidate(faceGroupsProvider),
    ),
    data: (data) {
      final others = orderedFaceGroups(
        [
          for (final g in data.groups)
            if (g.id != exclude) g,
        ],
        order,
        unnamedFewestFirst: data.fewestFirst,
      );

      if (others.isEmpty) {
        return EmptyMessage(
          message: l10n.personMergeNobody,
          icon: Icons.person_outline,
        );
      }

      // The people list is paged, so this dialog pages too: without it
      // the only people on offer would be the first forty, and the one
      // being looked for is as likely to be further down.
      return LoadMoreOnScroll(
        hasMore: data.hasMore,
        onLoadMore: () => ref.read(faceGroupsProvider.notifier).loadMore(),
        child: ListView.builder(
          itemCount: others.length + (data.loadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= others.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final person = others[index];

            return ListTile(
              leading: FaceThumbnail(face: person, size: 40),
              title: Text(describePerson(person, l10n)),
              onTap: () => Navigator.of(context).pop(MoveToPerson(person)),
            );
          },
        ),
      );
    },
  );
}

/// Where the move dialog sends the photos.
sealed class FaceMoveTarget {
  const FaceMoveTarget();
}

/// To someone there already is.
class MoveToPerson extends FaceMoveTarget {
  final FaceGroup person;

  const MoveToPerson(this.person);
}

/// To a person made for them, named before anything is sent.
class MoveToNewPerson extends FaceMoveTarget {
  const MoveToNewPerson();
}

/// Out of this person, without a name: one more of the unnamed.
class MoveToUnlabeled extends FaceMoveTarget {
  const MoveToUnlabeled();
}

/// How a person reads in a list: their name, or the word for the unnamed with
/// the count that tells them apart.
String describePerson(FaceGroup person, AppLocalizations l10n) =>
    faceGroupIsNamed(person)
    ? person.label!
    : unlabeledFaceLabel(l10n.personUnlabeled, person.imageFaceCount);
