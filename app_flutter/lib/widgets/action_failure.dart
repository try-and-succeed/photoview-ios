import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import 'certificate_review.dart';

/// Reports an action that failed, offering the way out when there is one.
///
/// A screen that fails renders [CertificateErrorMessage] and lets the user
/// look at the certificate. An *action* — scanning an album, renaming a person
/// — had no such way: it could only say that the certificate is not trusted,
/// on a screen whose contents still look fine because they were loaded before.
/// Since pinned certificates are short-lived (Caddy's internal CA issues
/// twelve-hour leaves), that is what an app left overnight does to the next
/// thing the user taps — reported as "nothing happens".
///
/// [message] wraps the description of the error in whatever sentence fits the
/// action. [retry] runs the action again once the certificate is accepted.
///
/// Any message already on screen is replaced rather than queued: tapping a
/// button twice otherwise plays the first answer, then the second, and a
/// failure can sit behind a stale success for as long as the queue is.
Future<void> showActionFailure(
  BuildContext context,
  WidgetRef ref, {
  required Object error,
  required String Function(String description) message,
  FutureOr<void> Function()? retry,
  CertificateProbe probe = probeCertificate,
  CertificateConfirm confirm = showCertificateDialog,
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);

  messenger.removeCurrentSnackBar();

  if (error is! CertificateNotTrustedException) {
    messenger.showSnackBar(
      SnackBar(content: Text(message(describeError(error, l10n)))),
    );
    return;
  }

  final endpoint = error.endpoint;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message(describeError(error, l10n))),
      // Long enough to be read and acted on. The default four seconds is the
      // length of a message nobody has to do anything about.
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: l10n.certificateReview,
        onPressed: () async {
          if (!context.mounted) return;

          final review = await reviewCertificate(
            context: context,
            ref: ref,
            endpoint: endpoint,
            probe: probe,
            confirm: confirm,
          );

          switch (review.outcome) {
            // Both are worth trying again: an accepted certificate because it
            // is now trusted, nothing-to-show because the next attempt either
            // succeeds or names the error that actually applies.
            case CertificateReview.trusted:
            case CertificateReview.nothingToShow:
              // Storing the decision takes a moment, and the screen can be
              // left in it — back out of an album, and the retry would run
              // against a dead context, which throws before it reaches its
              // own `mounted` check. The messenger is safe either way: it
              // lives above the navigator, which is why a message can outlive
              // the screen that raised it.
              if (!context.mounted) return;
              await retry?.call();
            case CertificateReview.declined:
              messenger
                ..removeCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(content: Text(l10n.certificateNotAccepted)),
                );
            case CertificateReview.notStored:
              messenger
                ..removeCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      l10n.certificateTrustFailed(
                        describeError(review.error ?? '', l10n),
                      ),
                    ),
                  ),
                );
            case CertificateReview.abandoned:
              break;
          }
        },
      ),
    ),
  );
}
