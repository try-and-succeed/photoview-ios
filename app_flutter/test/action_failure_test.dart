import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/trusted_certificates.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/widgets/action_failure.dart';

import 'support/localized_app.dart';

final _endpoint = Uri.parse('https://photoview.lan/api/graphql');

final _certificate = TrustedCertificate(
  host: 'photoview.lan',
  sha256: 'bb' * 32,
  subject: 'CN=photoview.lan',
  issuer: 'CN=Caddy Local Authority',
  validFrom: DateTime.utc(2026, 9, 21, 15),
  // Twelve hours, as Caddy's internal CA issues them — which is why a session
  // that worked in the evening fails on the next thing tapped in the morning.
  validTo: DateTime.utc(2026, 9, 22, 3),
);

class _RecordingStore extends TrustedCertificateStore {
  final trusted = <TrustedCertificate>[];

  @override
  Future<void> trust(TrustedCertificate certificate) async {
    trusted.add(certificate);
  }
}

class _UnwritableStore extends TrustedCertificateStore {
  @override
  Future<void> trust(TrustedCertificate certificate) async {
    throw StateError('secure storage is full');
  }
}

/// A screen with one button, which fails the way an action does.
class _Harness extends ConsumerWidget {
  final Object error;
  final VoidCallback? onRetry;
  final Future<TrustedCertificate?> Function(Uri) probe;
  final Future<bool> Function(BuildContext, TrustedCertificate, {bool replacesTrusted}) confirm;

  const _Harness({
    required this.error,
    required this.probe,
    required this.confirm,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => showActionFailure(
          context,
          ref,
          error: error,
          message: (description) => 'Scan failed: $description',
          retry: onRetry,
          probe: probe,
          confirm: confirm,
        ),
        child: const Text('act'),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Object error,
  required TrustedCertificateStore store,
  VoidCallback? onRetry,
  Future<TrustedCertificate?> Function(Uri)? probe,
  bool accept = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [trustedCertificatesProvider.overrideWithValue(store)],
      child: localizedApp(
        home: _Harness(
          error: error,
          onRetry: onRetry,
          probe: probe ?? (_) async => _certificate,
          confirm: (_, _, {bool replacesTrusted = false}) async => accept,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('an ordinary failure is just reported', (tester) async {
    await _pump(
      tester,
      error: const ApiException('Connection failed', problem: ApiProblem.unreachable),
      store: _RecordingStore(),
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Scan failed:'), findsOneWidget);
    expect(
      find.text('Review certificate'),
      findsNothing,
      reason: 'there is no certificate to look at',
    );
  });

  testWidgets('an untrusted certificate can be reviewed from the message', (
    tester,
  ) async {
    final store = _RecordingStore();
    var retried = 0;

    await _pump(
      tester,
      error: CertificateNotTrustedException(_endpoint),
      store: store,
      onRetry: () => retried++,
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();

    // The whole point: the action that failed offers the way out, instead of
    // leaving the user on a screen whose contents still look fine.
    expect(find.text('Review certificate'), findsOneWidget);

    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(store.trusted.single.sha256, _certificate.sha256);
    expect(retried, 1, reason: 'the scan is tried again once it can work');
  });

  testWidgets('declining the certificate says so and retries nothing', (
    tester,
  ) async {
    final store = _RecordingStore();
    var retried = 0;

    await _pump(
      tester,
      error: CertificateNotTrustedException(_endpoint),
      store: store,
      onRetry: () => retried++,
      accept: false,
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(store.trusted, isEmpty);
    expect(retried, 0);
    expect(find.textContaining('not accepted'), findsOneWidget);
  });

  testWidgets('a certificate that cannot be stored is not reported as trusted', (
    tester,
  ) async {
    var retried = 0;

    await _pump(
      tester,
      error: CertificateNotTrustedException(_endpoint),
      store: _UnwritableStore(),
      onRetry: () => retried++,
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(retried, 0, reason: 'retrying would fail the same way');
    expect(find.textContaining('Could not trust this certificate'), findsOneWidget);
  });

  testWidgets('nothing to show is worth one more attempt', (tester) async {
    var retried = 0;

    // A probe that finds nothing means the certificate validates on its own
    // now, or the host is unreachable — the next attempt settles which.
    await _pump(
      tester,
      error: CertificateNotTrustedException(_endpoint),
      store: _RecordingStore(),
      onRetry: () => retried++,
      probe: (_) async => null,
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(retried, 1);
  });

  testWidgets('a second failure replaces the first instead of queueing', (
    tester,
  ) async {
    await _pump(
      tester,
      error: const ApiException('Connection failed', problem: ApiProblem.unreachable),
      store: _RecordingStore(),
    );

    await tester.tap(find.text('act'));
    await tester.pump();
    await tester.tap(find.text('act'));
    await tester.pump();

    // Two identical messages in a queue is what made a failed scan look like a
    // successful one: the answer on screen belonged to an earlier tap.
    expect(find.textContaining('Scan failed:'), findsOneWidget);

    await tester.pumpAndSettle();
  });
}
