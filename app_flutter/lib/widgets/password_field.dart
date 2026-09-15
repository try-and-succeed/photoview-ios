import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// A password field whose contents can be shown while typing.
///
/// Hidden by default and hidden again whenever the field is rebuilt from
/// scratch — leaving the sign-in form and coming back does not bring a
/// revealed password back on screen.
///
/// Suggestions and autocorrect stay off in both states. With the text
/// visible, a keyboard would otherwise treat the password as an ordinary word:
/// learn it, and offer it back later in other apps.
class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;

  /// The field's label; "Password" in the app language when not given.
  final String? labelText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const PasswordField({
    super.key,
    required this.controller,
    this.focusNode,
    this.labelText,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: !_revealed,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      autofillHints: const [AutofillHints.password],
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.labelText ?? l10n.loginPassword,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          // A real button, not a gesture on the field: reachable by keyboard
          // and announced by a screen reader.
          tooltip: _revealed ? l10n.passwordHide : l10n.passwordShow,
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
      ),
    );
  }
}
