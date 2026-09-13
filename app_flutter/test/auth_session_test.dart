import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';

SavedServer _server(String host, String token, DateTime lastUsed) =>
    SavedServer(
      endpoint: Uri.parse('http://$host/api/graphql'),
      username: 'admin',
      token: token,
      lastUsed: lastUsed,
    );

final _older = _server('a', 'token-a', DateTime(2026, 1, 1));
final _newer = _server('b', 'token-b', DateTime(2026, 6, 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late SessionStore store;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    store = SessionStore();
    await store.remember(_older);
    await store.remember(_newer);

    container = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        // The real cleaner needs path_provider, which is unavailable here.
        imageCacheCleanerProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
  });

  group('AuthNotifier.sessionExpired', () {
    test('reopens the most recently used server on build', () async {
      final session = await container.read(authProvider.future);
      expect(session?.endpoint.host, 'b');
    });

    test('signs out when the active session is the one that failed', () async {
      await container.read(authProvider.future);
      await container.read(authProvider.notifier).sessionExpired(
        _newer.session,
      );

      expect(container.read(sessionProvider), isNull);
      expect(container.read(expiredSessionProvider)?.endpoint.host, 'b');

      // Its token is dropped, so tapping the entry cannot fail the same way.
      expect((await store.servers()).map((s) => s.endpoint.host), ['a']);
    });

    test('keeps the active session when an older one failed', () async {
      await container.read(authProvider.future);

      // A slow request against server A errors after the user switched to B.
      await container.read(authProvider.notifier).sessionExpired(
        _older.session,
      );

      final active = container.read(sessionProvider);
      expect(active, isNotNull, reason: 'server B must stay signed in');
      expect(active!.endpoint.host, 'b');
      expect(active.token, 'token-b');

      // No misleading "your sign-in expired" notice for a server the user is
      // not even looking at.
      expect(container.read(expiredSessionProvider), isNull);

      // Only the failing server is forgotten.
      expect((await store.servers()).map((s) => s.endpoint.host), ['b']);
    });
  });

  group('AuthNotifier sign-out paths', () {
    test('switchServer clears the session but keeps every entry', () async {
      await container.read(authProvider.future);
      await container.read(authProvider.notifier).switchServer();

      expect(container.read(sessionProvider), isNull);
      expect(await store.servers(), hasLength(2));
    });

    test('logOut forgets only the active entry', () async {
      await container.read(authProvider.future);
      await container.read(authProvider.notifier).logOut();

      expect(container.read(sessionProvider), isNull);
      expect((await store.servers()).map((s) => s.endpoint.host), ['a']);
    });

    test('forget leaves the session alone for a different server', () async {
      await container.read(authProvider.future);
      await container.read(authProvider.notifier).forget(_older);

      expect(container.read(sessionProvider)?.endpoint.host, 'b');
      expect((await store.servers()).map((s) => s.endpoint.host), ['b']);
    });

    test('signs out even when clearing the image cache fails', () async {
      final failing = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          imageCacheCleanerProvider.overrideWithValue(
            () async => throw Exception('cache unavailable'),
          ),
        ],
      );
      addTearDown(failing.dispose);

      await failing.read(authProvider.future);
      await failing.read(authProvider.notifier).switchServer();

      expect(
        failing.read(sessionProvider),
        isNull,
        reason: 'housekeeping must not keep the user signed in',
      );
    });
  });
}
