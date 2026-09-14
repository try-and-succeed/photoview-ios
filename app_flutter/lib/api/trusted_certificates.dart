import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';
import 'trusted_cas.dart';

/// A certificate the user has been shown and has explicitly accepted.
class TrustedCertificate {
  final String host;
  final String sha256;
  final String subject;
  final String issuer;
  final DateTime validFrom;
  final DateTime validTo;

  const TrustedCertificate({
    required this.host,
    required this.sha256,
    required this.subject,
    required this.issuer,
    required this.validFrom,
    required this.validTo,
  });

  /// Groups of four hex characters, the way certificate viewers print it.
  String get readableFingerprint {
    final upper = sha256.toUpperCase();
    return [
      for (var i = 0; i < upper.length; i += 4)
        upper.substring(i, i + 4 > upper.length ? upper.length : i + 4),
    ].join(' ');
  }
}

String certificateFingerprint(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

TrustedCertificate describeCertificate(X509Certificate cert, String host) =>
    TrustedCertificate(
      host: host,
      sha256: certificateFingerprint(cert),
      subject: cert.subject,
      issuer: cert.issuer,
      validFrom: cert.startValidity,
      validTo: cert.endValidity,
    );

/// Remembers which otherwise-untrusted certificates the user accepted.
///
/// Self-hosted Photoview instances are commonly served with a certificate from
/// a private authority (Caddy's internal CA, for example), which no device
/// trusts. Rather than accepting every certificate — which would forfeit the
/// protection TLS provides — the app trusts one exact certificate per host,
/// after showing the user its fingerprint. If that certificate later changes,
/// the connection fails again and the user is asked afresh.
///
/// **These pins widen trust, they do not narrow it.** A pin is only ever
/// created for a certificate the TLS stack rejected, and it is consulted only
/// from [HttpClient.badCertificateCallback] — which the stack does not call
/// when a certificate validates on its own. So a host that later presents a
/// certificate issued by a system root, or by a CA the user imported, is
/// accepted without the pin being consulted.
///
/// That is deliberate. Enforcing the pin on top of a valid chain would be
/// strict pinning, and it would break the path this app actually recommends:
/// importing the server's CA (see [TrustedCaStore]), after which Caddy's
/// twice-daily reissues validate normally. Enforcing it would mean prompting
/// the user twice a day for a certificate that is already verifiable.
class TrustedCertificateStore {
  static const _key = 'trusted-certificates';

  final FlutterSecureStorage _storage;

  /// host -> SHA-256 fingerprint. Held in memory because
  /// [HttpClient.badCertificateCallback] is synchronous.
  final Map<String, String> _accepted = {};

  TrustedCertificateStore({FlutterSecureStorage? storage})
    : _storage = storage ?? photoviewSecureStorage;

  Future<void> load() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (_) {
      // Leave the set empty rather than erasing: an unreadable store is
      // recoverable on a later launch, and the user is only asked to accept a
      // certificate again in the meantime.
      return;
    }

    _accepted.clear();
    if (raw == null || raw.isEmpty) return;

    for (final entry in raw.split(';')) {
      final parts = entry.split('=');
      if (parts.length == 2) _accepted[parts[0]] = parts[1];
    }
  }

  bool isTrusted(X509Certificate certificate, String host) =>
      _accepted[host] == certificateFingerprint(certificate);

  Future<void> trust(TrustedCertificate certificate) =>
      _commit({..._accepted, certificate.host: certificate.sha256});

  Future<void> forget(String host) =>
      _commit({..._accepted}..remove(host));

  Map<String, String> get accepted => Map.unmodifiable(_accepted);

  /// Stores [next], and only adopts it in memory once that succeeded.
  ///
  /// Writing second would let a failed write leave the running app trusting a
  /// certificate the store does not know about — or, worse, distrusting one it
  /// still holds, so a revoked pin returns after a restart.
  Future<void> _commit(Map<String, String> next) async {
    await _persist(next);
    _accepted
      ..clear()
      ..addAll(next);
  }

  Future<void> _persist(Map<String, String> accepted) async {
    if (accepted.isEmpty) {
      await _storage.delete(key: _key);
      return;
    }

    final raw = accepted.entries.map((e) => '${e.key}=${e.value}').join(';');
    await _storage.write(key: _key, value: raw);
  }
}

/// Routes every Dart HTTP request through the user's TLS decisions.
///
/// Installed globally so GraphQL calls and image loading share them; both go
/// through `dart:io`'s [HttpClient]. Two mechanisms, in order of preference:
/// an imported CA validates its certificates normally, and a pinned
/// certificate is accepted as a specific exception.
class TrustedCertificateHttpOverrides extends HttpOverrides {
  final TrustedCertificateStore pinned;
  final TrustedCaStore authorities;

  TrustedCertificateHttpOverrides({
    required this.pinned,
    required this.authorities,
  });

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Must go through super: the HttpClient constructor consults the installed
    // overrides, so building one here would call straight back into this
    // method and overflow the stack.
    return super.createHttpClient(authorities.securityContext ?? context)
      ..badCertificateCallback = (cert, host, port) =>
          pinned.isTrusted(cert, host);
  }
}

/// Fetches the certificate a host presents, so it can be shown to the user.
///
/// Returns null when the host is reachable and its certificate already
/// validates, or when it cannot be reached at all.
Future<TrustedCertificate?> probeCertificate(Uri url) async {
  X509Certificate? captured;

  const step = Duration(seconds: 10);

  final client = HttpClient()
    ..connectionTimeout = step
    ..badCertificateCallback = (cert, host, port) {
      captured = cert;
      // Accept for this probe only; this client is discarded immediately and
      // the response body is never read.
      return true;
    };

  try {
    // connectionTimeout only bounds establishing the connection. A server that
    // completes the handshake and then stalls on the status line or body would
    // otherwise hang the sign-in flow that awaits this probe, so each step
    // gets its own deadline.
    final request = await client.headUrl(url).timeout(step);
    final response = await request.close().timeout(step);
    await response.drain<void>().timeout(step);
  } catch (_) {
    // A capture is all this probe needs; failures past the handshake are fine.
  } finally {
    client.close(force: true);
  }

  final cert = captured;
  return cert == null ? null : describeCertificate(cert, url.host);
}
