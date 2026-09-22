import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/trusted_certificates.dart';
import 'package:photoview/main.dart';
import 'package:photoview/screens/welcome_screen.dart';
import 'package:photoview/state/auth.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// An auth notifier the test can sign out, as an expired token does.
class _ControllableAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;

  void expire() => state = const AsyncData(null);
}

/// Answers every screen with nothing, so the shell can be built without a
/// server.
class _EmptyClient extends PhotoviewClient {
  _EmptyClient() : super(_session);

  @override
  Future<List<TimelineMedia>> timeline({
    required int limit,
    required int offset,
    DateTime? fromDate,
  }) async => const [];

  @override
  Future<List<AlbumItem>> myAlbums() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('signing out closes the screens opened above the shell', (
    tester,
  ) async {
    late ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_ControllableAuth.new),
          clientProvider.overrideWithValue(_EmptyClient()),
          trustedCertificatesProvider.overrideWithValue(
            TrustedCertificateStore(),
          ),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return const PhotoviewApp();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // What the user has open when the token dies: an album, pushed above the
    // shell.
    final navigator = Navigator.of(
      tester.element(find.byType(Scaffold).first),
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('an open album')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('an open album'), findsOneWidget);

    // The server stops accepting the token.
    (container.read(authProvider.notifier) as _ControllableAuth).expire();
    await tester.pumpAndSettle();

    expect(
      find.text('an open album'),
      findsNothing,
      reason: 'a screen of a session that has ended must not stay on top',
    );
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });
}
