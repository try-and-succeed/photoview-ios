import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/trusted_certificates.dart';
import '../state/auth.dart';
import 'certificate_dialog.dart';

/// Shown when a request failed because the server's certificate is not
/// trusted, with a way to look at it and accept it.
///
/// Without this the screen offered "Retry", which could only ever fail the
/// same way: a certificate does not become trusted by asking again. Pinned
/// certificates are short-lived — Caddy's internal CA renews twice a day — so
/// this happens to a working session, not just at sign-in.
class CertificateErrorMessage extends ConsumerStatefulWidget {
  final Uri endpoint;

  /// Called after the certificate is accepted, to run the failed request again.
  final VoidCallback? onRetry;

  const CertificateErrorMessage({
    super.key,
    required this.endpoint,
    this.onRetry,
  });

  @override
  ConsumerState<CertificateErrorMessage> createState() =>
      _CertificateErrorMessageState();
}

class _CertificateErrorMessageState
    extends ConsumerState<CertificateErrorMessage> {
  bool _busy = false;
  String? _note;

  Future<void> _review() async {
    setState(() {
      _busy = true;
      _note = null;
    });

    try {
      final certificate = await probeCertificate(widget.endpoint);
      if (!mounted) return;

      if (certificate == null) {
        setState(
          () => _note =
              'Could not read a certificate from ${widget.endpoint.host}.',
        );
        return;
      }

      final store = ref.read(trustedCertificatesProvider);
      final pinned = store.accepted[certificate.host];

      final accepted = await showCertificateDialog(
        context,
        certificate,
        replacesTrusted: pinned != null && pinned != certificate.sha256,
      );
      if (!mounted) return;

      if (!accepted) {
        setState(() => _note = 'Certificate was not accepted.');
        return;
      }

      await store.trust(certificate);
      if (!mounted) return;

      widget.onRetry?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.gpp_maybe,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'The certificate ${widget.endpoint.host} is presenting is not '
              'trusted. If it was renewed, you can check the new one and '
              'accept it.',
              textAlign: TextAlign.center,
            ),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(
                _note!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_busy)
              const CircularProgressIndicator()
            else
              FilledButton.tonal(
                onPressed: _review,
                child: const Text('Review certificate'),
              ),
          ],
        ),
      ),
    );
  }
}
