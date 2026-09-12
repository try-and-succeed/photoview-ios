import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';

SavedServer _server(String url, String username, String token) => SavedServer(
  endpoint: Uri.parse(url),
  username: username,
  token: token,
  lastUsed: DateTime.now(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('starts with nothing remembered', () async {
      expect(await SessionStore().servers(), isEmpty);
      expect(await SessionStore().mostRecent(), isNull);
    });

    test('remembers a server and reopens it as the most recent', () async {
      final store = SessionStore();
      await store.remember(
        _server('http://host:8081/api/graphql', 'admin', 'tok'),
      );

      final recent = await store.mostRecent();
      expect(recent, isNotNull);
      expect(recent!.username, 'admin');
      expect(recent.session.token, 'tok');
      expect(recent.session.endpoint.toString(), 'http://host:8081/api/graphql');
    });

    test('keeps the most recently used server first', () async {
      final store = SessionStore();
      await store.remember(_server('http://a/api/graphql', 'u', 't1'));
      await store.remember(_server('http://b/api/graphql', 'u', 't2'));

      expect((await store.servers()).map((s) => s.endpoint.host), ['b', 'a']);

      await store.touch(_server('http://a/api/graphql', 'u', 't1'));
      expect((await store.servers()).map((s) => s.endpoint.host), ['a', 'b']);
    });

    test('replaces the entry for the same account rather than duplicating', () async {
      final store = SessionStore();
      await store.remember(_server('http://a/api/graphql', 'admin', 'old'));
      await store.remember(_server('http://a/api/graphql', 'admin', 'new'));

      final servers = await store.servers();
      expect(servers, hasLength(1));
      expect(servers.single.token, 'new');
    });

    test('keeps two accounts on the same server apart', () async {
      final store = SessionStore();
      await store.remember(_server('http://a/api/graphql', 'alice', 't1'));
      await store.remember(_server('http://a/api/graphql', 'bob', 't2'));

      expect(await store.servers(), hasLength(2));
    });

    test('forgets one server by id', () async {
      final store = SessionStore();
      final a = _server('http://a/api/graphql', 'u', 't1');
      await store.remember(a);
      await store.remember(_server('http://b/api/graphql', 'u', 't2'));

      await store.forget(a.id);

      final servers = await store.servers();
      expect(servers, hasLength(1));
      expect(servers.single.endpoint.host, 'b');
    });

    test('survives a corrupt stored value', () async {
      FlutterSecureStorage.setMockInitialValues({
        'saved-servers': 'not json',
      });

      expect(await SessionStore().servers(), isEmpty);
    });
  });

  group('SessionStore migration', () {
    test('carries an existing single sign-in into the server list', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access-token': 'legacy-token',
        'server-instance': 'http://192.168.0.47:8081/api/graphql',
      });

      final store = SessionStore();
      final recent = await store.mostRecent();

      expect(recent, isNotNull);
      expect(recent!.token, 'legacy-token');
      expect(recent.endpoint.host, '192.168.0.47');
    });

    test('clears the old keys so the migration runs once', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access-token': 'legacy-token',
        'server-instance': 'http://host/api/graphql',
      });

      const storage = FlutterSecureStorage();
      await SessionStore().servers();

      expect(await storage.read(key: 'access-token'), isNull);
      expect(await storage.read(key: 'server-instance'), isNull);
      expect(await storage.read(key: 'saved-servers'), isNotNull);
    });

    test('ignores a half-written legacy session', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access-token': 'legacy-token',
      });

      expect(await SessionStore().servers(), isEmpty);
    });
  });

  group('SavedServer', () {
    test('labels an entry by host and port', () {
      expect(
        _server('http://192.168.0.47:8081/api/graphql', 'u', 't').label,
        '192.168.0.47:8081',
      );
      expect(
        _server('https://photoview.lan/api/graphql', 'u', 't').label,
        'photoview.lan',
      );
    });

    test('survives a round trip through JSON', () {
      final original = _server('https://host/api/graphql', 'admin', 'tok');
      final restored = SavedServer.fromJson(original.toJson());

      expect(restored, isNotNull);
      expect(restored!.id, original.id);
      expect(restored.token, original.token);
      expect(restored.username, original.username);
    });

    test('rejects JSON without a usable endpoint or token', () {
      expect(SavedServer.fromJson({'endpoint': 'nonsense'}), isNull);
      expect(
        SavedServer.fromJson({'endpoint': 'https://host/api/graphql'}),
        isNull,
      );
    });
  });
}
