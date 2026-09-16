import 'dart:async';

import '../api/capabilities.dart';
import '../api/client.dart';
import '../api/media_files.dart';
import '../api/session.dart';
import '../api/trusted_cas.dart';
import 'app_localizations.dart';

/// [error] as a sentence in the app language.
///
/// Failures the app can name are translated; what the server says in its own
/// words — a GraphQL error, a refused sign-in — is shown as sent, since the
/// app cannot know every message a server may produce.
String describeError(Object? error, AppLocalizations l10n) => switch (error) {
  null => l10n.errorUnknown,
  // Subclasses of ApiException, so before it.
  UnsupportedFieldException(:final field) => l10n.errorUnsupportedField(field),
  PermissionDeniedException() => l10n.errorPermissionDenied,
  ApiException(:final problem?, :final detail) => _problem(
    l10n,
    problem,
    detail,
  ),
  LoginFailure(:final problem?, :final detail) => _problem(
    l10n,
    problem,
    detail,
  ),
  ApiException(:final message) || LoginFailure(:final message) => message,
  UnauthorizedException() => l10n.errorSignInRejected,
  CertificateNotTrustedException(:final endpoint) =>
    l10n.errorCertificateNotTrusted(endpoint.host),
  DownloadCancelledException() => l10n.downloadCancelled,
  StorageUnavailable(:final cause) => l10n.errorStorageUnavailable('$cause'),
  InvalidCertificateFile(:final problem, :final count) => switch (problem) {
    CertificateFileProblem.missing => l10n.certFileMissing,
    CertificateFileProblem.unreadable => l10n.certFileUnreadable,
    CertificateFileProblem.alreadyTrusted => l10n.certFileAlreadyTrusted,
    CertificateFileProblem.severalCertificates => l10n.certFileSeveral(count),
    CertificateFileProblem.invalidBase64 => l10n.certFileInvalidBase64,
  },
  TimeoutException() => l10n.errorTimeout,
  _ => '$error',
};

String _problem(AppLocalizations l10n, ApiProblem problem, String? detail) {
  final about = detail ?? '';

  return switch (problem) {
    ApiProblem.invalidInstanceUrl => l10n.errorInvalidInstanceUrl,
    ApiProblem.noTlsHandshake => l10n.errorNoTlsHandshake(about),
    ApiProblem.loginFailed => l10n.errorLoginFailed,
    ApiProblem.noData => l10n.errorNoData,
    ApiProblem.noAnswer => l10n.errorNoAnswer,
    ApiProblem.httpStatus => l10n.errorHttpStatus(about),
    ApiProblem.certificateNotTrusted => l10n.errorCertificateReason(about),
    ApiProblem.unreachable => l10n.errorUnreachable(about),
    ApiProblem.notGraphql => l10n.errorNotGraphql,
    ApiProblem.timeout => l10n.errorTimeout,
    // Whatever it was, its own description beats saying nothing.
    ApiProblem.unknown => detail ?? l10n.errorUnknown,
    ApiProblem.albumNotFound => l10n.errorAlbumNotFound,
    ApiProblem.mediaNotFound => l10n.errorMediaNotFound,
    ApiProblem.invalidMapJson => l10n.errorInvalidMapJson,
    ApiProblem.invalidMapShape => l10n.errorInvalidMapShape,
    ApiProblem.scanRefused => l10n.errorScanRefused,
  };
}
