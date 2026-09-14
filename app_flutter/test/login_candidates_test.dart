import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/session.dart';

Session _session(Uri endpoint) => Session(endpoint: endpoint, token: 'tok');

Future<bool> _certificate(Uri _) async => true;
Future<bool> _noCertificate(Uri _) async => false;

void main() {
  /// The candidates a bare host produces: HTTPS first, then plain HTTP.
  final bare = PhotoviewClient.candidateBases('photoview.lan')
      .expand((b) => [b.resolve('graphql'), b.resolve('api/graphql')])
      .toList();

  group('PhotoviewClient.attemptCandidates', () {
    test('a bare host is tried over HTTPS before HTTP', () {
      expect(bare.first.scheme, 'https');
      expect(bare.last.scheme, 'http');
    });

    test('works down the list while failures are inconclusive', () async {
      final tried = <Uri>[];

      final session = await PhotoviewClient.attemptCandidates(
        bare,
        (endpoint) async {
          tried.add(endpoint);
          if (tried.length < 3) throw const ApiException('not graphql here');
          return _session(endpoint);
        },
        presentsCertificate: _certificate,
      );

      expect(tried, hasLength(3));
      expect(session.endpoint, bare[2]);
    });

    test('stops at an untrusted certificate instead of trying HTTP', () async {
      final tried = <Uri>[];

      await expectLater(
        PhotoviewClient.attemptCandidates(
          bare,
          (endpoint) async {
            tried.add(endpoint);
            throw CertificateNotTrustedException(endpoint);
          },
          presentsCertificate: _certificate,
        ),
        throwsA(isA<CertificateNotTrustedException>()),
      );

      // The decisive assertion: the password must not be offered to a plain
      // HTTP endpoint just because HTTPS presented a suspicious certificate.
      expect(tried, hasLength(1));
      expect(
        tried.every((u) => u.scheme == 'https'),
        isTrue,
        reason: 'no cleartext attempt after a TLS trust failure',
      );
    });

    test('falls back to HTTP when the HTTPS port presents no certificate',
        () async {
      final tried = <Uri>[];

      // What a plain-HTTP port looks like over HTTPS: the handshake fails as a
      // TlsException, but no certificate was ever presented.
      final session = await PhotoviewClient.attemptCandidates(
        bare,
        (endpoint) async {
          tried.add(endpoint);
          if (endpoint.scheme == 'https') {
            throw CertificateNotTrustedException(endpoint);
          }
          return _session(endpoint);
        },
        presentsCertificate: _noCertificate,
      );

      expect(session.endpoint.scheme, 'http');
      expect(tried.where((u) => u.scheme == 'https'), hasLength(2));
    });

    test('names the missing handshake when only HTTPS was tried', () async {
      final explicit = PhotoviewClient.candidateBases('https://192.168.0.47:8081')
          .map((b) => b.resolve('graphql'))
          .toList();

      await expectLater(
        PhotoviewClient.attemptCandidates(
          explicit,
          (endpoint) async => throw CertificateNotTrustedException(endpoint),
          presentsCertificate: _noCertificate,
        ),
        throwsA(
          isA<LoginFailure>().having(
            (e) => e.message,
            'message',
            contains('did not complete a TLS handshake'),
          ),
        ),
      );
    });

    test('stops as soon as the server refuses the credentials', () async {
      final tried = <Uri>[];

      await expectLater(
        PhotoviewClient.attemptCandidates(
          bare,
          (endpoint) async {
            tried.add(endpoint);
            throw const LoginFailure('invalid credentials');
          },
          presentsCertificate: _certificate,
        ),
        throwsA(isA<LoginFailure>()),
      );

      expect(tried, hasLength(1));
    });

    test('reports the last failure when nothing worked', () async {
      await expectLater(
        PhotoviewClient.attemptCandidates(
          bare,
          (_) async => throw const ApiException('unreachable'),
          presentsCertificate: _certificate,
        ),
        throwsA(isA<LoginFailure>()),
      );
    });

    test('an explicit http:// address is honoured as given', () {
      final explicit = PhotoviewClient.candidateBases('http://192.168.0.47:8081');

      expect(explicit, hasLength(1));
      expect(explicit.single.scheme, 'http');
    });
  });
}
