import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/trusted_certificates.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
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

  /// Seams for the test, which can neither open a socket nor tap a dialog.
  /// Both default to the real thing.
  final Future<TrustedCertificate?> Function(Uri) probe;
  final Future<bool> Function(
    BuildContext,
    TrustedCertificate, {
    bool replacesTrusted,
  })
  confirm;

  const CertificateErrorMessage({
    super.key,
    required this.endpoint,
    this.onRetry,
    this.probe = probeCertificate,
    this.confirm = showCertificateDialog,
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
      final certificate = await widget.probe(widget.endpoint);
      if (!mounted) return;

      // Nothing to show means the certificate now validates on its own — a CA
      // imported since, say — or that the host cannot be reached. Neither is a
      // question about a certificate, and trying again settles both: it
      // succeeds, or it fails with the error that actually applies.
      if (certificate == null) {
        final retry = widget.onRetry;
        if (retry != null) {
          retry();
        } else {
          setState(
            () => _note = AppLocalizations.of(
              context,
            ).certificateCouldNotRead(widget.endpoint.host),
          );
        }
        return;
      }

      final store = ref.read(trustedCertificatesProvider);
      final pinned = store.accepted[certificate.host];

      final accepted = await widget.confirm(
        context,
        certificate,
        replacesTrusted: pinned != null && pinned != certificate.sha256,
      );
      if (!mounted) return;

      if (!accepted) {
        setState(
          () => _note = AppLocalizations.of(context).certificateNotAccepted,
        );
        return;
      }

      await store.trust(certificate);
      if (!mounted) return;

      // Every other screen that failed on this certificate is still holding
      // that failure; this is what sends them back to the server.
      ref.read(tlsTrustGenerationProvider.notifier).state++;

      widget.onRetry?.call();
    } catch (error) {
      // Storing the decision can fail — secure storage is not guaranteed to be
      // writable. Without this the button simply came back and the user tried
      // again forever, never told that the certificate was not saved.
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(
          () => _note = l10n.certificateTrustFailed(describeError(error, l10n)),
        );
      }
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
              AppLocalizations.of(
                context,
              ).certificateErrorBody(widget.endpoint.host),
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
                child: Text(AppLocalizations.of(context).certificateReview),
              ),
          ],
        ),
      ),
    );
  }
}
