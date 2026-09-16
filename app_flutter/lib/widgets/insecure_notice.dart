import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// How exposed the connection to an instance is.
enum InsecureConnectionRisk {
  /// HTTPS — typed, or implied by an address without a scheme — or nothing
  /// typed yet.
  none,

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
  /// Only an explicit `http://` is unencrypted: an address without a scheme
  /// is signed in to over HTTPS and never falls back.
  static InsecureConnectionRisk riskOfText(String text) =>
      text.trim().toLowerCase().startsWith('http://')
      ? InsecureConnectionRisk.certain
      : InsecureConnectionRisk.none;

  /// Best effort host for display, for an address that may have no scheme.
  /// Empty when there is none yet; the notice then names "this server" in the
  /// app language.
  static String hostOfText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';

    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    return Uri.tryParse(withScheme)?.host ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final message = switch (risk) {
      InsecureConnectionRisk.certain => l10n.insecureConnection(
        host.isEmpty ? l10n.thisServer : host,
      ),
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
            Icons.lock_open,
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
