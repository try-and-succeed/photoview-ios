import 'package:flutter/material.dart';

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
  final String labelText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const PasswordField({
    super.key,
    required this.controller,
    this.focusNode,
    this.labelText = 'Password',
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
        labelText: widget.labelText,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          // A real button, not a gesture on the field: reachable by keyboard
          // and announced by a screen reader.
          tooltip: _revealed ? 'Hide password' : 'Show password',
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
      ),
    );
  }
}
