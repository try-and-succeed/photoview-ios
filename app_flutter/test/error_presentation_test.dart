import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/trusted_certificates.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/widgets/async_states.dart';
import 'package:photoview/widgets/certificate_error.dart';

import 'support/localized_app.dart';

Widget _host(
  Widget child, {
  List<Override> overrides = const [],
  Locale? locale,
}) => ProviderScope(
  overrides: overrides,
  child: localizedApp(home: Scaffold(body: child), locale: locale),
);

final _certificate = TrustedCertificate(
  host: 'photoview.lan',
  sha256: 'aa' * 32,
  subject: 'CN=photoview.lan',
  issuer: 'CN=Caddy Local Authority',
  validFrom: DateTime.utc(2026, 9, 13),
  validTo: DateTime.utc(2026, 9, 14),
);

/// A store whose write fails, as it does on a device with unwritable secure
/// storage.
class _UnwritableStore extends TrustedCertificateStore {
  @override
  Future<void> trust(TrustedCertificate certificate) async {
    throw Exception('secure storage is unavailable');
  }
}

/// A store that accepts without touching the secure-storage channel, which
/// does not answer under the test binding.
class _RecordingStore extends TrustedCertificateStore {
  final trusted = <TrustedCertificate>[];

  @override
  Future<void> trust(TrustedCertificate certificate) async {
    trusted.add(certificate);
  }
}

void main() {
  group('ErrorMessage.forError', () {
    testWidgets('offers a retry for an ordinary failure', (tester) async {
      var retried = 0;

      await tester.pumpWidget(
        _host(
          ErrorMessage.forError(
            const ApiException('Could not reach the server'),
            onRetry: () => retried++,
          ),
        ),
      );

      expect(find.text('Could not reach the server'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retried, 1);
    });

    testWidgets('words the failure in the app language', (tester) async {
      await tester.pumpWidget(
        _host(
          ErrorMessage.forError(
            const ApiException(
              'Could not reach the server: Connection refused',
              problem: ApiProblem.unreachable,
              detail: 'Connection refused',
            ),
            onRetry: () {},
          ),
          locale: const Locale('de'),
        ),
      );

      expect(
        find.text('Der Server ist nicht erreichbar: Connection refused'),
        findsOneWidget,
      );
      expect(find.text('Erneut versuchen'), findsOneWidget);
    });

    testWidgets('offers to review an untrusted certificate, not a retry', (
      tester,
    ) async {
      // Retrying cannot help: a certificate does not become trusted by asking
      // again. The user has to see it and decide.
      await tester.pumpWidget(
        _host(
          ErrorMessage.forError(
            CertificateNotTrustedException(
              Uri.parse('https://photoview.lan/api/graphql'),
            ),
            onRetry: () {},
          ),
        ),
      );

      expect(find.byType(CertificateErrorMessage), findsOneWidget);
      expect(find.text('Review certificate'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.textContaining('photoview.lan'), findsOneWidget);
    });

    testWidgets('says so when the certificate could not be stored', (
      tester,
    ) async {
      // Without a catch the button simply came back and the user tried again
      // forever, never told that the decision was not saved.
      var retried = 0;

      await tester.pumpWidget(
        _host(
          CertificateErrorMessage(
            endpoint: Uri.parse('https://photoview.lan/api/graphql'),
            onRetry: () => retried++,
            probe: (_) async => _certificate,
            confirm: (_, _, {bool replacesTrusted = false}) async => true,
          ),
          overrides: [
            trustedCertificatesProvider.overrideWithValue(_UnwritableStore()),
          ],
        ),
      );

      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not trust this certificate'),
          findsOneWidget);
      expect(retried, 0, reason: 'nothing was stored, so nothing to retry');
    });

    testWidgets('retries the screen once the certificate is accepted', (
      tester,
    ) async {
      var retried = 0;
      final store = _RecordingStore();

      await tester.pumpWidget(
        _host(
          CertificateErrorMessage(
            endpoint: Uri.parse('https://photoview.lan/api/graphql'),
            onRetry: () => retried++,
            probe: (_) async => _certificate,
            confirm: (_, _, {bool replacesTrusted = false}) async => true,
          ),
          overrides: [
            trustedCertificatesProvider.overrideWithValue(store),
          ],
        ),
      );

      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(store.trusted.single.sha256, _certificate.sha256);
      expect(retried, 1);
    });

    testWidgets('retries when there is no certificate left to review', (
      tester,
    ) async {
      // The certificate validates by now (a CA was imported) or the host is
      // gone. A note saying no certificate could be read was a dead end;
      // retrying either works or reports the error that applies.
      var retried = 0;
      var asked = false;

      await tester.pumpWidget(
        _host(
          CertificateErrorMessage(
            endpoint: Uri.parse('https://photoview.lan/api/graphql'),
            onRetry: () => retried++,
            probe: (_) async => null,
            confirm: (_, _, {bool replacesTrusted = false}) async {
              asked = true;
              return true;
            },
          ),
        ),
      );

      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(retried, 1);
      expect(asked, isFalse, reason: 'there was no certificate to ask about');
      expect(find.textContaining('Could not read a certificate'), findsNothing);
    });

    testWidgets('presents a missing server feature calmly', (tester) async {
      await tester.pumpWidget(
        _host(
          ErrorMessage.forError(
            UnsupportedFieldException(field: 'scanAlbum', type: 'Mutation'),
            onRetry: () {},
          ),
        ),
      );

      expect(find.textContaining('does not support this yet'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });
}
