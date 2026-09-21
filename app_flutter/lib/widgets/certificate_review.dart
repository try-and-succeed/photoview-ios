import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/trusted_certificates.dart';
import '../state/auth.dart';
import 'certificate_dialog.dart';

// Re-exported so that asking about a certificate needs one import, defaults
// included: both places that ask take them as seams for their tests.
export '../api/trusted_certificates.dart' show TrustedCertificate, probeCertificate;
export 'certificate_dialog.dart' show showCertificateDialog;

/// Seams for tests, which can neither open a socket nor tap a dialog.
typedef CertificateProbe = Future<TrustedCertificate?> Function(Uri);
typedef CertificateConfirm =
    Future<bool> Function(
      BuildContext,
      TrustedCertificate, {
      bool replacesTrusted,
    });

/// What came of showing the user a certificate.
enum CertificateReview {
  /// Accepted and stored — whatever failed is worth trying again.
  trusted,

  /// The user looked at it and said no.
  declined,

  /// Nothing to show: it validates on its own now — an authority imported
  /// since, say — or the host cannot be reached at all. Trying again settles
  /// which of the two it is.
  nothingToShow,

  /// Accepted, but the decision could not be stored.
  notStored,

  /// The caller went away while the question was open.
  abandoned,
}

/// Fetches the certificate [endpoint] presents, shows it, and pins it if the
/// user accepts.
///
/// Shared by the two places that ask: the full-screen message a failed query
/// leaves behind, and the one offered when a single action fails. Pinned
/// certificates are short-lived — Caddy's internal CA issues twelve-hour
/// leaves — so a session that worked in the evening fails in the morning, and
/// then it is not a screen that fails but whatever the user just tapped.
Future<({CertificateReview outcome, Object? error})> reviewCertificate({
  required BuildContext context,
  required WidgetRef ref,
  required Uri endpoint,
  CertificateProbe probe = probeCertificate,
  CertificateConfirm confirm = showCertificateDialog,
}) async {
  // Taken now, while the caller is certainly alive: it is used after the
  // storage write, which is a point `ref.read` may no longer be reached from.
  final trustGeneration = ref.read(tlsTrustGenerationProvider.notifier);

  final certificate = await probe(endpoint);
  if (!context.mounted) {
    return (outcome: CertificateReview.abandoned, error: null);
  }
  // Read only once there is a certificate to weigh against it. A caller with
  // nothing to show never needs the store, and must not be made to provide one.
  if (certificate == null) {
    return (outcome: CertificateReview.nothingToShow, error: null);
  }

  final store = ref.read(trustedCertificatesProvider);
  final pinned = store.accepted[certificate.host];
  final accepted = await confirm(
    context,
    certificate,
    replacesTrusted: pinned != null && pinned != certificate.sha256,
  );
  if (!context.mounted) {
    return (outcome: CertificateReview.abandoned, error: null);
  }
  if (!accepted) return (outcome: CertificateReview.declined, error: null);

  try {
    await store.trust(certificate);
  } catch (error) {
    // Storing the decision can fail — secure storage is not guaranteed to be
    // writable. Saying so beats a button that comes back and works no better
    // the second time.
    return (outcome: CertificateReview.notStored, error: error);
  }

  // Not guarded by `context.mounted`: the certificate is stored by now, and
  // every screen that failed on it is still holding that failure. A tab switch
  // while the write was in flight would otherwise leave them stuck on a
  // certificate the app has since accepted.
  trustGeneration.state++;

  return (outcome: CertificateReview.trusted, error: null);
}
