import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/session.dart';

Session _session(Uri endpoint) => Session(endpoint: endpoint, token: 'tok');

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

      final session = await PhotoviewClient.attemptCandidates(bare, (
        endpoint,
      ) async {
        tried.add(endpoint);
        if (tried.length < 3) throw const ApiException('not graphql here');
        return _session(endpoint);
      });

      expect(tried, hasLength(3));
      expect(session.endpoint, bare[2]);
    });

    test('stops at an untrusted certificate instead of trying HTTP', () async {
      final tried = <Uri>[];

      await expectLater(
        PhotoviewClient.attemptCandidates(bare, (endpoint) async {
          tried.add(endpoint);
          throw CertificateNotTrustedException(endpoint);
        }),
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

    test('stops as soon as the server refuses the credentials', () async {
      final tried = <Uri>[];

      await expectLater(
        PhotoviewClient.attemptCandidates(bare, (endpoint) async {
          tried.add(endpoint);
          throw const LoginFailure('invalid credentials');
        }),
        throwsA(isA<LoginFailure>()),
      );

      expect(tried, hasLength(1));
    });

    test('reports the last failure when nothing worked', () async {
      await expectLater(
        PhotoviewClient.attemptCandidates(
          bare,
          (_) async => throw const ApiException('unreachable'),
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
