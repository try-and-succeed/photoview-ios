import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/trusted_certificates.dart';

/// Asks the user whether to trust one specific certificate, showing enough of
/// it that the decision is informed rather than blind.
Future<bool> showCertificateDialog(
  BuildContext context,
  TrustedCertificate certificate,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _CertificateDialog(certificate: certificate),
  );

  return accepted ?? false;
}

class _CertificateDialog extends StatelessWidget {
  final TrustedCertificate certificate;

  const _CertificateDialog({required this.certificate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dates = DateFormat.yMMMd();

    return AlertDialog(
      icon: Icon(Icons.gpp_maybe, color: theme.colorScheme.error, size: 36),
      title: const Text('Untrusted certificate'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${certificate.host} identifies itself with a certificate this '
              'device cannot verify. That is normal for a self-hosted server '
              'using its own certificate authority.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _Row(label: 'Issued by', value: _clean(certificate.issuer)),
            if (_clean(certificate.subject).isNotEmpty)
              _Row(label: 'Issued to', value: _clean(certificate.subject)),
            _Row(
              label: 'Valid',
              value: '${dates.format(certificate.validFrom)} – '
                  '${dates.format(certificate.validTo)}',
            ),
            const SizedBox(height: 12),
            Text(
              'SHA-256 fingerprint',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              certificate.readableFingerprint,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Only continue if this fingerprint matches your server. This '
              'exact certificate will be trusted from now on, and you will be '
              'asked again if it ever changes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Trust'),
        ),
      ],
    );
  }

  /// Certificate names arrive as `/CN=…` style strings; show the useful part.
  static String _clean(String name) {
    final match = RegExp(r'CN\s*=\s*([^,/]+)').firstMatch(name);
    return (match?.group(1) ?? name).trim();
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
