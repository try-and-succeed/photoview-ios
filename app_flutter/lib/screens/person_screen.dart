import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../state/people_order.dart';
import '../widgets/action_failure.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/face_grid.dart';
import '../widgets/load_more.dart';
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
      builder: (context) => _NameDialog(initial: _label),
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
      final stored = await ref.read(faceActionsProvider).rename(
        widget.faceGroup.id,
        label,
      );
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
    final other = await showDialog<FaceGroup>(
      context: context,
      builder: (context) => _PickPersonDialog(exclude: widget.faceGroup.id),
    );
    if (other == null || !mounted) return;

    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);

    try {
      final label = await ref
          .read(faceActionsProvider)
          .merge(widget.faceGroup.id, [other.id]);

      if (!mounted) return;
      setState(() => _label = label);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.personMerged(_describe(other, l10n)))),
      );
    } catch (error) {
      if (mounted) {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.personMergeFailed,
          retry: _merge,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final media = ref.watch(personMediaProvider(widget.faceGroup.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(_label ?? l10n.personUnlabeled),
        actions: [
          if (_busy)
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
      body: media.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage.forError(
          error,
          onRetry: () =>
              ref.invalidate(personMediaProvider(widget.faceGroup.id)),
        ),
        data: (data) => data.isEmpty
            ? EmptyMessage(message: l10n.personEmpty)
            : ScrollableView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    sliver: MediaSliverGrid(media: data),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
      ),
    );
  }
}

/// Asks for the name. Returns the typed name, an empty string to remove the
/// one there is, or null when the user backed out.
class _NameDialog extends StatefulWidget {
  final String? initial;

  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
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

/// Picks the person to fold into this one.
///
/// The whole list, named and unnamed alike: the two tiles that turn out to be
/// the same person are often one of each — the reason for merging in the
/// first place. Sorted the way the People tab is, so the order is the one the
/// user just came from.
class _PickPersonDialog extends ConsumerWidget {
  /// The person doing the absorbing, which cannot absorb itself.
  final String exclude;

  const _PickPersonDialog({required this.exclude});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final people = ref.watch(faceGroupsProvider);
    final order =
        ref.watch(peopleOrderProvider).valueOrNull ?? PeopleOrder.alphabetical;

    return AlertDialog(
      title: Text(l10n.personMergePick),
      content: SizedBox(
        width: 320,
        height: 380,
        child: people.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorMessage.forError(
            error,
            onRetry: () => ref.invalidate(faceGroupsProvider),
          ),
          data: (data) {
            final others = orderedFaceGroups(
              [for (final g in data.groups) if (g.id != exclude) g],
              order,
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
              onLoadMore: () =>
                  ref.read(faceGroupsProvider.notifier).loadMore(),
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
                    title: Text(_describe(person, l10n)),
                    onTap: () => Navigator.of(context).pop(person),
                  );
                },
              ),
            );
          },
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
}

/// How a person reads in a list: their name, or the word for the unnamed with
/// the count that tells them apart.
String _describe(FaceGroup person, AppLocalizations l10n) =>
    faceGroupIsNamed(person)
    ? person.label!
    : unlabeledFaceLabel(l10n.personUnlabeled, person.imageFaceCount);
