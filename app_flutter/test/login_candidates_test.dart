import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/session.dart';

Session _session(Uri endpoint) => Session(endpoint: endpoint, token: 'tok');

Future<bool> _certificate(Uri _) async => true;
Future<bool> _noCertificate(Uri _) async => false;

/// The endpoints [PhotoviewClient.login] tries for what the user typed.
List<Uri> _candidates(String instance) => PhotoviewClient.candidateBases(
  instance,
).expand((b) => [b.resolve('graphql'), b.resolve('api/graphql')]).toList();

void main() {
  final bare = _candidates('192.168.0.47:8081');

  group('PhotoviewClient.attemptCandidates', () {
    test('a bare host is only ever tried over HTTPS', () {
      expect(bare, hasLength(2));
      expect(bare.every((u) => u.scheme == 'https'), isTrue);
    });

    test('works down the list while failures are inconclusive', () async {
      final tried = <Uri>[];

      final session = await PhotoviewClient.attemptCandidates(
        bare,
        (endpoint) async {
          tried.add(endpoint);
          if (tried.length < 2) throw const ApiException('not graphql here');
          return _session(endpoint);
        },
        presentsCertificate: _certificate,
      );

      expect(tried, hasLength(2));
      expect(session.endpoint, bare[1]);
    });

    test('stops at an untrusted certificate', () async {
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

      expect(tried, hasLength(1));
    });

    test('a port without TLS is not reported as a certificate problem, and '
        'points to http:// instead of connecting that way', () async {
      final tried = <Uri>[];

      // What a plain-HTTP port looks like over HTTPS: the handshake fails as a
      // TlsException, but no certificate was ever presented.
      await expectLater(
        PhotoviewClient.attemptCandidates(
          bare,
          (endpoint) async {
            tried.add(endpoint);
            throw CertificateNotTrustedException(endpoint);
          },
          presentsCertificate: _noCertificate,
        ),
        throwsA(
          isA<LoginFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not complete a TLS handshake'),
              contains('http://192.168.0.47:8081'),
            ),
          ),
        ),
      );

      expect(
        tried.every((u) => u.scheme == 'https'),
        isTrue,
        reason: 'plain HTTP is only used when the user types it',
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
      final explicit = _candidates('http://192.168.0.47:8081');

      expect(explicit, isNotEmpty);
      expect(explicit.every((u) => u.scheme == 'http'), isTrue);
    });
  });
}
