import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/trusted_certificates.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/certificate_error.dart';

import 'support/localized_app.dart';

final _testSession = Session(
  endpoint: Uri.parse('https://photoview.lan/api/graphql'),
  token: 'tok',
  username: 'admin',
);

final _certificate = TrustedCertificate(
  host: 'photoview.lan',
  sha256: 'aa' * 32,
  subject: 'CN=photoview.lan',
  issuer: 'CN=Caddy Local Authority',
  validFrom: DateTime.utc(2026, 9, 16),
  validTo: DateTime.utc(2026, 9, 17),
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _testSession;
}

/// Refuses until the certificate is accepted, the way the server does behind a
/// private authority whose certificate has been reissued.
class _UntrustedUntilAccepted extends PhotoviewClient {
  _UntrustedUntilAccepted() : super(_testSession);

  bool trusted = false;
  int calls = 0;

  @override
  Future<List<AlbumItem>> myAlbums() async {
    calls++;
    if (!trusted) {
      throw CertificateNotTrustedException(_testSession.endpoint);
    }
    return const [AlbumItem(id: '2', title: 'Landscapes')];
  }
}

class _RecordingStore extends TrustedCertificateStore {
  final trusted = <TrustedCertificate>[];

  @override
  Future<void> trust(TrustedCertificate certificate) async {
    trusted.add(certificate);
  }
}

void main() {
  test('a screen that failed on the certificate retries once it is trusted', () async {
    // The bug this covers: accepting the certificate in the album view left
    // every other tab holding its own failure, and the user was asked again —
    // per tab — for a certificate that was by then trusted.
    final client = _UntrustedUntilAccepted();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authProvider.future);
    await expectLater(
      container.read(myAlbumsProvider.future),
      throwsA(isA<CertificateNotTrustedException>()),
    );
    expect(client.calls, 1);

    client.trusted = true;
    container.read(tlsTrustGenerationProvider.notifier).state++;

    expect(
      await container.read(myAlbumsProvider.future),
      [isA<AlbumItem>().having((a) => a.title, 'title', 'Landscapes')],
    );
    expect(client.calls, 2, reason: 'the failed request was made again');
  });

  testWidgets('accepting a certificate tells the rest of the app', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        trustedCertificatesProvider.overrideWithValue(_RecordingStore()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedApp(
          home: Scaffold(
            body: CertificateErrorMessage(
              endpoint: Uri.parse('https://photoview.lan/api/graphql'),
              probe: (_) async => _certificate,
              confirm: (_, _, {bool replacesTrusted = false}) async => true,
            ),
          ),
        ),
      ),
    );

    expect(container.read(tlsTrustGenerationProvider), 0);

    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(
      container.read(tlsTrustGenerationProvider),
      1,
      reason: 'other screens have no other way of learning about it',
    );
  });

  testWidgets('a certificate that is refused changes nothing', (tester) async {
    final container = ProviderContainer(
      overrides: [
        trustedCertificatesProvider.overrideWithValue(_RecordingStore()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedApp(
          home: Scaffold(
            body: CertificateErrorMessage(
              endpoint: Uri.parse('https://photoview.lan/api/graphql'),
              probe: (_) async => _certificate,
              confirm: (_, _, {bool replacesTrusted = false}) async => false,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(container.read(tlsTrustGenerationProvider), 0);
  });
}
