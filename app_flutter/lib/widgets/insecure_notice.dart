import 'package:flutter/material.dart';

/// How exposed the connection to an instance is.
enum InsecureConnectionRisk {
  /// HTTPS, or nothing typed yet.
  none,

  /// No scheme given. HTTPS is tried first, but sign-in falls back to plain
  /// HTTP if the instance cannot be reached that way — and a bare host name is
  /// the usual way a LAN instance is entered, so this is the common case, not
  /// an edge one.
  possible,

  /// An explicit `http://` address: unencrypted for certain.
  certain,
}

/// Points out that traffic to this instance is, or may be, unencrypted.
///
/// Plain HTTP is deliberately permitted — self-hosted instances are commonly
/// served that way on a LAN, and refusing would make them unreachable. But the
/// auth token travels with every request, including each thumbnail, so the
/// user should be able to see when that is happening rather than having to
/// infer it from the address.
class InsecureConnectionNotice extends StatelessWidget {
  final String host;
  final InsecureConnectionRisk risk;

  const InsecureConnectionNotice({
    super.key,
    required this.host,
    this.risk = InsecureConnectionRisk.certain,
  });

  /// Risk for an endpoint that is already connected, so the scheme is settled.
  static InsecureConnectionRisk riskOf(Uri? url) => url?.scheme == 'http'
      ? InsecureConnectionRisk.certain
      : InsecureConnectionRisk.none;

  /// Risk for a half-typed address in a text field.
  ///
  /// A schemeless address counts: warning only about an explicit `http://`
  /// would stay silent in exactly the case where the password is about to be
  /// sent in the clear without the user having asked for it.
  static InsecureConnectionRisk riskOfText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return InsecureConnectionRisk.none;

    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://')) return InsecureConnectionRisk.certain;
    if (lower.startsWith('https://')) return InsecureConnectionRisk.none;

    return InsecureConnectionRisk.possible;
  }

  /// Best effort host for display, for an address that may have no scheme.
  static String hostOfText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'this server';

    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final host = Uri.tryParse(withScheme)?.host ?? '';

    return host.isEmpty ? 'this server' : host;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final message = switch (risk) {
      InsecureConnectionRisk.certain =>
        'Unencrypted connection to $host. Your sign-in travels with every '
            'request, so use this only on a network you trust.',
      InsecureConnectionRisk.possible =>
        'If $host cannot be reached over HTTPS, the app will connect '
            'unencrypted and your sign-in will travel with every request. '
            'Type https:// to require encryption.',
      InsecureConnectionRisk.none => '',
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            risk == InsecureConnectionRisk.certain
                ? Icons.lock_open
                : Icons.info_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
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
