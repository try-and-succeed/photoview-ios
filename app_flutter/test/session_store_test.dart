import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';

SavedServer _server(
  String url,
  String username,
  String token, {
  DateTime? lastUsed,
}) => SavedServer(
  endpoint: Uri.parse(url),
  username: username,
  token: token,
  // Ordering tests must pass distinct values: two calls in the same tick would
  // compare equal and the assertion could pass on insertion order alone.
  lastUsed: lastUsed ?? DateTime.now(),
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
      expect(recent.session?.token, 'tok');
      expect(
        recent.session?.endpoint.toString(),
        'http://host:8081/api/graphql',
      );
    });

    test('keeps the most recently used server first', () async {
      final store = SessionStore();
      final early = DateTime(2026, 1, 1);
      final later = DateTime(2026, 6, 1);

      // Written oldest-last so insertion order cannot stand in for sorting.
      await store.remember(
        _server('http://a/api/graphql', 'u', 't1', lastUsed: later),
      );
      await store.remember(
        _server('http://b/api/graphql', 'u', 't2', lastUsed: early),
      );

      expect((await store.servers()).map((s) => s.endpoint.host), ['a', 'b']);

      await store.touch(_server('http://b/api/graphql', 'u', 't2'));
      expect((await store.servers()).map((s) => s.endpoint.host), ['b', 'a']);
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

    test('signing out keeps the entry and drops only the token', () async {
      final store = SessionStore();
      final a = _server('http://a/api/graphql', 'u', 't1');
      await store.remember(a);

      await store.dropToken(a.id);

      final servers = await store.servers();
      expect(servers, hasLength(1), reason: 'the server stays on the list');
      expect(servers.single.token, isNull);
      expect(servers.single.username, 'u', reason: 'so only the password is typed');
      expect(servers.single.hasToken, isFalse);
      expect(servers.single.session, isNull);
    });

    test('a signed-out entry keeps its place in the list', () async {
      final store = SessionStore();
      final early = DateTime(2026, 1, 1);
      final later = DateTime(2026, 6, 1);
      final newer = _server('http://b/api/graphql', 'u', 't2', lastUsed: later);

      await store.remember(_server('http://a/api/graphql', 'u', 't1', lastUsed: early));
      await store.remember(newer);
      await store.dropToken(newer.id);

      expect(
        (await store.servers()).map((s) => s.endpoint.host),
        ['b', 'a'],
        reason: 'signing out must not reshuffle the list under the user',
      );
    });

    test('is not reopened on launch once signed out', () async {
      final store = SessionStore();
      final early = DateTime(2026, 1, 1);
      final later = DateTime(2026, 6, 1);
      final newer = _server('http://b/api/graphql', 'u', 't2', lastUsed: later);

      await store.remember(_server('http://a/api/graphql', 'u', 't1', lastUsed: early));
      await store.remember(newer);
      await store.dropToken(newer.id);

      // The most recent entry has no token left, so the next one down is the
      // one that can actually be opened.
      expect((await store.mostRecent())?.endpoint.host, 'a');

      await store.dropToken(_server('http://a/api/graphql', 'u', 't1').id);
      expect(await store.mostRecent(), isNull);
      expect(await store.servers(), hasLength(2), reason: 'both stay listed');
    });

    test('dropping a token twice changes nothing', () async {
      final store = SessionStore();
      final a = _server('http://a/api/graphql', 'u', 't1');
      await store.remember(a);

      await store.dropToken(a.id);
      await store.dropToken(a.id);
      await store.dropToken('http://nowhere/api/graphql|u');

      expect(await store.servers(), hasLength(1));
    });

    test('reads back an entry stored without a token', () async {
      FlutterSecureStorage.setMockInitialValues({
        'saved-servers':
            '[{"endpoint":"http://a/api/graphql","username":"u",'
            '"token":null,"lastUsed":"2026-01-01T00:00:00.000"}]',
      });

      final servers = await SessionStore().servers();
      expect(servers, hasLength(1));
      expect(servers.single.hasToken, isFalse);
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

    test('rejects JSON without a usable endpoint', () {
      expect(SavedServer.fromJson({'endpoint': 'nonsense'}), isNull);
      expect(SavedServer.fromJson({}), isNull);
    });

    test('keeps an entry whose token is gone', () {
      // A missing token is not a broken entry: it is a server the user has
      // signed out of, and dropping it here is what emptied the list.
      final restored = SavedServer.fromJson({
        'endpoint': 'https://host/api/graphql',
        'username': 'admin',
      });

      expect(restored, isNotNull);
      expect(restored!.hasToken, isFalse);
      expect(restored.username, 'admin');
    });

    test('survives a round trip once signed out', () {
      final original = _server('https://host/api/graphql', 'admin', 'tok');
      final restored = SavedServer.fromJson(original.signedOut.toJson());

      expect(restored, isNotNull);
      expect(restored!.id, original.id);
      expect(restored.hasToken, isFalse);
    });
  });
}
