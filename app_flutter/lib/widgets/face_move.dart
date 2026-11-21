import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../api/session.dart';
import '../l10n/app_localizations.dart';
import '../state/auth.dart';
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
  // Whether [retry] is offered for any failure, not only for a certificate
  // that can be accepted — see `showActionFailure`.
  bool retryAnyError,
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

      case MoveToNewPerson(name: final typed):
        final name = (await showDialog<String>(
          context: context,
          builder: (context) =>
              PersonNameDialog(initial: null, suggestion: typed),
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
    FaceGroup person, {
    String? account,
  }) {
    final owner = account ?? _signedIn(ref);

    return run(
      () async {
        _stillSignedIn(ref, owner);
        await ref.read(faceActionsProvider).moveFaces(faceIds, person.id);
        return l10n.personFacesMoved(describePerson(person, l10n));
      },
      failed: l10n.personFacesMoveFailed,
      retry: () => _sendMove(ref, l10n, faceIds, person, account: owner),
    );
  }

  static String? _signedIn(WidgetRef ref) => signedInAccount(ref);

  static void _stillSignedIn(WidgetRef ref, String? owner) =>
      ensureStillSignedIn(ref, owner);

  /// Lifts the faces out into a group of their own and names it.
  ///
  /// Two requests, and the second can fail on its own. A retry then names the
  /// group the first one made, instead of lifting the faces out a second time
  /// — they are no longer where they were, and a second split would leave an
  /// unnamed group behind with nothing to tell it apart.
  ///
  /// The retry is offered for any failure, not only for a certificate: once
  /// the faces are out, the photos that were ticked are gone from this person
  /// and cannot be sent again, so the retry is the only way left to give the
  /// new person the name the user confirmed. The message then says where the
  /// photos are.
  ///
  /// Both requests go only to the account the move started on ([account],
  /// kept for the retry as well) — checked before each, as the account can
  /// change while the first is under way. See [_stillSignedIn].
  Future<void> _sendMoveToNew(
    WidgetRef ref,
    AppLocalizations l10n,
    List<String> faceIds,
    String name, {
    String? created,
    String? account,
  }) {
    final actions = ref.read(faceActionsProvider);
    final owner = account ?? _signedIn(ref);
    var made = created;

    return run(
      () async {
        if (made == null) {
          _stillSignedIn(ref, owner);
          made = await actions.detachFaces(faceIds);
        }
        final group = made;
        // Out, but the server named no group to give the name to: the faces
        // are a new person without one, and the message says only that.
        if (group == null) return l10n.personFacesDetached;
        _stillSignedIn(ref, owner);
        final stored = await actions.rename(group, name);
        return l10n.personFacesMoved(stored ?? name);
      },
      // Read when it fails, by which time it is known whether the faces are
      // out already.
      failed: (error) => made == null
          ? l10n.personFacesMoveFailed(error)
          : l10n.personFacesNameFailed(error),
      retry: () => _sendMoveToNew(
        ref,
        l10n,
        faceIds,
        name,
        created: made,
        account: owner,
      ),
      retryAnyError: true,
    );
  }

  /// The ids as they were when the action was asked for — see [_sendMove].
  Future<void> _sendDetach(
    WidgetRef ref,
    AppLocalizations l10n,
    List<String> faceIds, {
    String? account,
  }) {
    final owner = account ?? _signedIn(ref);

    return run(
      () async {
        _stillSignedIn(ref, owner);
        await ref.read(faceActionsProvider).detachFaces(faceIds);
        return l10n.personFacesDetached;
      },
      failed: l10n.personFacesDetachFailed,
      retry: () => _sendDetach(ref, l10n, faceIds, account: owner),
    );
  }
}

/// The account signed in now — the one the face and group ids came from
/// when an action starts.
String? signedInAccount(WidgetRef ref) => ref.read(sessionProvider)?.serverId;

/// Throws unless [owner] is still the one signed in.
///
/// Every request goes to whoever is signed in when it runs. The ids belong
/// to the account the action started on; sent to another — after a sign-in
/// elsewhere while a request or a retry was pending — they would move,
/// split, rename or confirm whatever has those ids there.
void ensureStillSignedIn(WidgetRef ref, String? owner) {
  if (signedInAccount(ref) != owner) throw const AccountChangedException();
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

  /// Filled in for a person who has no name yet — what was typed while
  /// looking for them. Unlike [initial], nothing there to remove.
  final String? suggestion;

  const PersonNameDialog({super.key, required this.initial, this.suggestion});

  @override
  State<PersonNameDialog> createState() => _PersonNameDialogState();
}

class _PersonNameDialogState extends State<PersonNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? widget.suggestion ?? '',
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
class PickPersonDialog extends ConsumerStatefulWidget {
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
  ConsumerState<PickPersonDialog> createState() => _PickPersonDialogState();
}

class _PickPersonDialogState extends ConsumerState<PickPersonDialog> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final people = ref.watch(faceGroupsProvider);
    final order =
        ref.watch(peopleOrderProvider).valueOrNull ?? PeopleOrder.nameAscending;
    final query = _filter.text.trim();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        height: 380,
        child: Column(
          children: [
            // Not focused on opening: the keyboard would cover most of the
            // list, and most of the time the person is near the top anyway.
            TextField(
              controller: _filter,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.personFilterHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_filter.clear),
                      ),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            // Above the list rather than in it, so they are there at once —
            // before the people have loaded, and however far down the user
            // scrolls.
            if (widget.offerNewAndUnlabeled) ...[
              // One line while a name is typed, and that name in it: the
              // keyboard leaves room for little more than a name or two below,
              // and what the entry does is plain once the name is there.
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: Text(
                  query.isEmpty
                      ? l10n.personMoveToNew
                      : l10n.personMoveToNewNamed(query),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: query.isEmpty ? Text(l10n.personMoveToNewHint) : null,
                dense: query.isNotEmpty,
                // A name typed and not found is most likely the new person's.
                onTap: () => Navigator.of(context)
                    .pop(MoveToNewPerson(name: query.isEmpty ? null : query)),
              ),
              // Not while looking for a name: the unnamed have none to find,
              // and the keyboard leaves little room.
              if (query.isEmpty)
                ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title: Text(l10n.personUnlabeled),
                  subtitle: Text(l10n.personMoveToUnlabeledHint),
                  onTap: () =>
                      Navigator.of(context).pop(const MoveToUnlabeled()),
                ),
              const Divider(),
            ],
            Expanded(child: _people(context, people, order, query, l10n)),
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
    AsyncValue<FaceGroupsData> people,
    PeopleOrder order,
    String query,
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
            if (g.id != widget.exclude && personMatches(g, query)) g,
        ],
        order,
        unnamedFewestFirst: data.fewestFirst,
      );

      if (others.isEmpty) {
        return EmptyMessage(
          message: query.isEmpty
              ? l10n.personMergeNobody
              : l10n.personFilterNoMatch,
          icon: Icons.person_outline,
        );
      }

      // The people list is paged, so this dialog pages too: without it
      // the only people on offer would be the first forty, and the one
      // being looked for is as likely to be further down. Not while
      // filtering: every named person is loaded with the first page (see
      // FaceGroupsNotifier), so further pages hold only the unnamed, which a
      // name never matches.
      return LoadMoreOnScroll(
        hasMore: query.isEmpty && data.hasMore,
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
  /// What was typed into the filter, offered as the name.
  final String? name;

  const MoveToNewPerson({this.name});
}

/// Whether [person] is kept by the dialog's name filter: everyone for an
/// empty [query], else the named whose name holds it, in any case.
bool personMatches(FaceGroup person, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  // The unnamed drop out by themselves: no label, or a blank one, holds a
  // query that is not blank.
  return person.label?.toLowerCase().contains(q) ?? false;
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
