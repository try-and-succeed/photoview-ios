import 'package:flutter/material.dart';

/// Points out that traffic to this instance is unencrypted.
///
/// Plain HTTP is deliberately permitted — self-hosted instances are commonly
/// served that way on a LAN, and refusing would make them unreachable. But the
/// auth token travels with every request, including each thumbnail, so the
/// user should be able to see when that is happening rather than having to
/// infer it from the address.
class InsecureConnectionNotice extends StatelessWidget {
  final String host;

  const InsecureConnectionNotice({super.key, required this.host});

  /// Whether [url] describes a connection worth warning about.
  static bool appliesTo(Uri? url) => url?.scheme == 'http';

  /// Same test for a half-typed address in a text field.
  static bool appliesToText(String text) =>
      text.trim().toLowerCase().startsWith('http://');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_open,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Unencrypted connection to $host. Your sign-in travels with '
              'every request, so use this only on a network you trust.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
