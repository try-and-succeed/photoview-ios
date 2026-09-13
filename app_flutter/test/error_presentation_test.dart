import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/widgets/async_states.dart';
import 'package:photoview/widgets/certificate_error.dart';

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(home: Scaffold(body: child)),
);

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
