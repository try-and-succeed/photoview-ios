import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/auth.dart';
import '../state/search_limit.dart';

/// Lets the user cap how many search hits are fetched.
///
/// Where the value is stored depends on the server, and the field says which —
/// a limit kept on the server follows the user to the web interface, one kept
/// here does not, and that is worth knowing before you set it.
class SearchLimitField extends ConsumerStatefulWidget {
  const SearchLimitField({super.key});

  @override
  ConsumerState<SearchLimitField> createState() => _SearchLimitFieldState();
}

class _SearchLimitFieldState extends ConsumerState<SearchLimitField> {
  final _controller = TextEditingController();

  /// The account whose stored limit the field is currently showing.
  ///
  /// The controller is filled from the stored limit once *per account*, not
  /// once per lifetime. Assigning on every build would let a slow response, or
  /// the reload after saving, overwrite what the user is typing — but a plain
  /// "only ever once" latched onto the signed-out moment during a server
  /// switch, when the limit legitimately reads as unset, and then never
  /// corrected itself. The field sat empty over a value that was still there.
  String? _initialisedFor;

  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final parsed = parseSearchLimit(_controller.text);
    final refusal = parsed.error;
    if (refusal != null) {
      setState(() => _error = _refusal(l10n, refusal));
      return;
    }

    setState(() {
      _error = null;
      _saving = true;
    });

    try {
      await ref.read(setSearchLimitProvider)(parsed.limit);
      if (!mounted) return;

      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_describe(l10n, parsed.limit))),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _describe(AppLocalizations l10n, int? limit) =>
      switch (limit) {
        null => l10n.searchLimitCleared,
        0 => l10n.searchLimitOff,
        _ => l10n.searchLimitSaved(limit),
      };

  static String _refusal(AppLocalizations l10n, SearchLimitError error) =>
      switch (error) {
        SearchLimitError.notWholeNumber => l10n.searchLimitNotWholeNumber,
        SearchLimitError.negative => l10n.searchLimitNegative,
        SearchLimitError.tooLarge =>
          l10n.searchLimitTooLarge(maxSearchResultLimit),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final limit = ref.watch(searchLimitProvider);
    final serverId = ref.watch(sessionProvider)?.serverId;

    final stored = limit.valueOrNull;
    if (stored != null && serverId != null && _initialisedFor != serverId) {
      _initialisedFor = serverId;
      _controller.text = stored.asText;
    }

    // A failure leaves the value null just as loading does, so without this
    // the row would sit on "Loading…" for ever with the field disabled and no
    // way to find out why or try again.
    final failed = limit.hasError;

    final subtitle = switch (stored?.source) {
      SearchLimitSource.server => l10n.searchLimitOnServer,
      SearchLimitSource.device => l10n.searchLimitOnDevice,
      null =>
        failed ? l10n.searchLimitReadFailed('${limit.error}') : l10n.loading,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.filter_list,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: stored != null && !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: l10n.searchLimitLabel,
                    hintText: l10n.searchLimitHint,
                    helperText: l10n.searchLimitHelper,
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              if (_saving)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (failed)
                TextButton(
                  onPressed: () => ref.invalidate(searchLimitProvider),
                  child: Text(l10n.actionRetry),
                )
              else
                TextButton(
                  onPressed: stored == null ? null : _save,
                  child: Text(l10n.actionSave),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
