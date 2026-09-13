import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/search_limit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSearchLimit', () {
    test('an empty field clears the setting', () {
      // Not zero. Zero means unlimited, which is a limit the user chose; an
      // empty field means they chose nothing and the default applies.
      for (final text in ['', '   ']) {
        final parsed = parseSearchLimit(text);
        expect(parsed.limit, isNull);
        expect(parsed.error, isNull);
      }
    });

    test('zero is a value, not an absence', () {
      final parsed = parseSearchLimit('0');
      expect(parsed.limit, 0);
      expect(parsed.error, isNull);
    });

    test('reads an ordinary number, spaces and all', () {
      expect(parseSearchLimit('50').limit, 50);
      expect(parseSearchLimit('  50 ').limit, 50);
    });

    test('refuses a negative limit instead of reinterpreting it', () {
      // The server rejects a negative limit outright ("search result limit
      // must not be negative"), so quietly turning -5 into 5 or 0 would store
      // something the user never asked for.
      final parsed = parseSearchLimit('-5');
      expect(parsed.limit, isNull);
      expect(parsed.error, contains('cannot be negative'));
    });

    test('refuses something that is not a number', () {
      for (final text in ['abc', '1.5', '1e6', '٣']) {
        expect(parseSearchLimit(text).error, isNotNull, reason: text);
      }
    });

    test('refuses a value above the cap', () {
      // A value past a 32-bit int came back from a live server as unlimited,
      // which would silently turn "as many as possible" into "all of them".
      expect(parseSearchLimit('2147483648').error, isNotNull);
      expect(parseSearchLimit('${maxSearchResultLimit + 1}').error, isNotNull);
      expect(parseSearchLimit('$maxSearchResultLimit').limit,
          maxSearchResultLimit);
    });
  });

  group('SearchLimit', () {
    test('an unset limit sends nothing, so the server default applies', () {
      const limit = SearchLimit(
        value: null,
        source: SearchLimitSource.server,
      );

      expect(limit.limitArgument, isNull);
      expect(limit.isUnlimited, isFalse);
      expect(limit.asText, '');
    });

    test('zero means unlimited and is sent as zero', () {
      const limit = SearchLimit(value: 0, source: SearchLimitSource.device);

      expect(limit.limitArgument, 0);
      expect(limit.isUnlimited, isTrue);
      expect(limit.asText, '0');
    });

    test('a number is passed through', () {
      const limit = SearchLimit(value: 40, source: SearchLimitSource.server);

      expect(limit.limitArgument, 40);
      expect(limit.isUnlimited, isFalse);
      expect(limit.asText, '40');
    });
  });

  group('SettingsStore', () {
    const serverA = 'http://a/api/graphql|admin';
    const serverB = 'http://b/api/graphql|admin';

    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('starts with nothing stored', () async {
      expect(await SettingsStore().searchResultLimit(serverA), isNull);
    });

    test('round-trips a limit', () async {
      await SettingsStore().setSearchResultLimit(serverA, 30);

      expect(await SettingsStore().searchResultLimit(serverA), 30);
    });

    test('keeps zero apart from unset', () async {
      await SettingsStore().setSearchResultLimit(serverA, 0);

      expect(await SettingsStore().searchResultLimit(serverA), 0);
    });

    test('null removes the limit', () async {
      final store = SettingsStore();
      await store.setSearchResultLimit(serverA, 30);
      await store.setSearchResultLimit(serverA, null);

      expect(await store.searchResultLimit(serverA), isNull);
    });

    test('keeps servers apart', () async {
      final store = SettingsStore();
      await store.setSearchResultLimit(serverA, 10);
      await store.setSearchResultLimit(serverB, 99);

      expect(await store.searchResultLimit(serverA), 10);
      expect(await store.searchResultLimit(serverB), 99);
    });

    test('removing one server leaves the other alone', () async {
      final store = SettingsStore();
      await store.setSearchResultLimit(serverA, 10);
      await store.setSearchResultLimit(serverB, 99);

      await store.setSearchResultLimit(serverA, null);

      expect(await store.searchResultLimit(serverA), isNull);
      expect(await store.searchResultLimit(serverB), 99);
    });

    test('reading degrades to nothing when the store is unreadable', () async {
      FlutterSecureStorage.setMockInitialValues({
        'device-settings': 'not json',
      });

      expect(await SettingsStore().searchResultLimit(serverA), isNull);
    });

    test('refuses to write rather than discard other servers', () async {
      // A write rebuilds the whole record, so treating a failed read as "empty"
      // would silently drop every other server's settings.
      FlutterSecureStoragePlatform.instance = _UnreadableStorage({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));

      await expectLater(
        SettingsStore().setSearchResultLimit(serverA, 10),
        throwsA(isA<StorageUnavailable>()),
      );
    });

    test('reading past an unreadable store reports nothing', () async {
      FlutterSecureStoragePlatform.instance = _UnreadableStorage({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));

      expect(await SettingsStore().searchResultLimit(serverA), isNull);
    });
  });
}

/// Storage whose reads always fail, standing in for a keystore that is not
/// available.
class _UnreadableStorage extends TestFlutterSecureStoragePlatform {
  _UnreadableStorage(super.data);

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    throw Exception('keystore unavailable');
  }
}
