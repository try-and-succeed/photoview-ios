import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/library.dart';
import '../widgets/async_states.dart';
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
    final l10n = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(initial: _label),
    );

    // Null is "cancelled"; an empty string is "remove the name", which the
    // server takes as a null label.
    if (name == null || !mounted) return;
    final label = name.trim().isEmpty ? null : name.trim();

    setState(() => _busy = true);
    try {
      final stored = await ref.read(faceActionsProvider).rename(
        widget.faceGroup.id,
        label,
      );
      if (mounted) setState(() => _label = stored);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.personNameFailed(describeError(error, l10n)))),
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
          else
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.personName,
              onPressed: _rename,
            ),
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
            : CustomScrollView(
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
