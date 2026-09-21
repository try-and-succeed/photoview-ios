import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import 'certificate_review.dart';

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
  final CertificateProbe probe;
  final CertificateConfirm confirm;

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
      final review = await reviewCertificate(
        context: context,
        ref: ref,
        endpoint: widget.endpoint,
        probe: widget.probe,
        confirm: widget.confirm,
      );
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      switch (review.outcome) {
        case CertificateReview.trusted:
          widget.onRetry?.call();
        case CertificateReview.nothingToShow:
          // Nothing to show is not a question about a certificate, and trying
          // again settles it: the request succeeds, or it fails with the error
          // that actually applies.
          final retry = widget.onRetry;
          if (retry != null) {
            retry();
          } else {
            setState(
              () => _note = l10n.certificateCouldNotRead(widget.endpoint.host),
            );
          }
        case CertificateReview.declined:
          setState(() => _note = l10n.certificateNotAccepted);
        case CertificateReview.notStored:
          setState(
            () => _note = l10n.certificateTrustFailed(
              describeError(review.error ?? '', l10n),
            ),
          );
        case CertificateReview.abandoned:
          break;
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
