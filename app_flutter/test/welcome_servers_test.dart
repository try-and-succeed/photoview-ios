import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/welcome_screen.dart';
import 'package:photoview/state/auth.dart';

import 'support/localized_app.dart';

SavedServer _server(String host, {String? token}) => SavedServer(
  endpoint: Uri.parse('http://$host/api/graphql'),
  username: 'admin',
  token: token,
  lastUsed: DateTime(2026, 6, 1),
);

/// A store whose read can be held open, to see what the screen shows meanwhile.
class _SlowStore extends SessionStore {
  final List<SavedServer> saved;
  final Future<void> until;

  _SlowStore(this.saved, this.until);

  @override
  Future<List<SavedServer>> servers() async {
    await until;
    return List.of(saved);
  }
}

Future<void> _pumpWelcome(WidgetTester tester, SessionStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionStoreProvider.overrideWithValue(store)],
      child: localizedApp(home: const WelcomeScreen()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('waits for the stored servers instead of showing the form', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });

    await _pumpWelcome(tester, _SlowStore([_server('a', token: 't')], gate.future));
    await tester.pump();

    // While the secure store is still being read, the sign-in form must not
    // flash up: the user would start typing into something about to vanish.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Instance'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('a'), findsOneWidget);
    expect(find.text('Instance'), findsNothing);
  });

  testWidgets('lists a signed-out server and says it needs a password', (
    tester,
  ) async {
    final store = SessionStore();
    await store.remember(_server('a', token: 't'));
    await store.dropToken(_server('a').id);

    await _pumpWelcome(tester, store);
    await tester.pumpAndSettle();

    expect(find.text('a'), findsOneWidget);
    expect(
      find.textContaining('Password required'),
      findsOneWidget,
      reason: 'the entry stays, but says what is missing',
    );
  });

  testWidgets('tapping a signed-out server prefills the sign-in form', (
    tester,
  ) async {
    final store = SessionStore();
    await store.remember(_server('a', token: 't'));
    await store.dropToken(_server('a').id);

    await _pumpWelcome(tester, store);
    await tester.pumpAndSettle();

    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    // The address and the user name come back filled in, so only the password
    // is left to type — and the endpoint is the address the user typed, not
    // the resolved GraphQL URL.
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    final values = fields.map((f) => f.controller?.text).toList();

    expect(values, contains('http://a'));
    expect(values, contains('admin'));
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('a server with a token is opened rather than prefilled', (
    tester,
  ) async {
    final store = SessionStore();
    await store.remember(_server('a', token: 't'));

    await _pumpWelcome(tester, store);
    await tester.pumpAndSettle();

    expect(find.textContaining('Password required'), findsNothing);
    expect(find.text('Instance'), findsNothing);
  });
}
