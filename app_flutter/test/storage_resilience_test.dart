import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/secure_storage.dart';
import 'package:photoview/api/session.dart';

/// Storage that fails the first [failures] reads, standing in for an Android
/// Keystore that is not ready yet.
class _FlakyStorage extends TestFlutterSecureStoragePlatform {
  _FlakyStorage(super.data, {this.failures = 1});

  int failures;
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads++;
    if (failures > 0) {
      failures--;
      throw Exception('keystore unavailable');
    }
    return super.read(key: key, options: options);
  }
}

const _storedServer =
    '[{"endpoint":"http://192.168.0.47:8081/api/graphql",'
    '"username":"admin","token":"tok",'
    '"lastUsed":"2026-09-12T19:00:00.000"}]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('secure storage configuration', () {
    test('does not let the plugin erase everything on an error', () {
      // resetOnError defaults to true and "will PERMANENTLY erase the data
      // when an error occurs", which would lose saved sign-ins on any hiccup.
      expect(photoviewSecureStorage.aOptions.toMap()['resetOnError'], 'false');
    });

    test('keeps a backup while re-encrypting after an algorithm change', () {
      final options = photoviewSecureStorage.aOptions.toMap();
      expect(options['migrateOnAlgorithmChange'], 'true');
      expect(options['migrateWithBackup'], 'true');
    });
  });

  group('SessionStore read resilience', () {
    test('retries a failed read and still finds the saved server', () async {
      final platform = _FlakyStorage({'saved-servers': _storedServer});
      FlutterSecureStoragePlatform.instance = platform;

      final servers = await SessionStore().servers();

      expect(platform.reads, greaterThan(1));
      expect(servers, hasLength(1));
      expect(servers.single.token, 'tok');
    });

    test('reports nothing rather than erasing when reads keep failing', () async {
      final data = {'saved-servers': _storedServer};
      FlutterSecureStoragePlatform.instance = _FlakyStorage(data, failures: 99);

      expect(await SessionStore().servers(), isEmpty);

      // The important part: the stored value is untouched, so a later launch
      // with a working keystore gets the servers back.
      expect(data['saved-servers'], _storedServer);
    });

    test('refuses to write rather than replace unreadable data', () async {
      // The dangerous case: a read fails, the list looks empty, and saving a
      // new sign-in would persist that one entry over all the others.
      final data = {'saved-servers': _storedServer};
      FlutterSecureStoragePlatform.instance = _FlakyStorage(data, failures: 99);

      await expectLater(
        SessionStore().remember(
          SavedServer(
            endpoint: Uri.parse('http://other/api/graphql'),
            username: 'bob',
            token: 'new',
            lastUsed: DateTime(2026, 9, 13),
          ),
        ),
        throwsA(isA<StorageUnavailable>()),
      );

      expect(data['saved-servers'], _storedServer);
    });

    test('recovers on the next attempt once the keystore works', () async {
      final data = {'saved-servers': _storedServer};
      final platform = _FlakyStorage(data, failures: 2);
      FlutterSecureStoragePlatform.instance = platform;

      // Both attempts of the first call fail.
      expect(await SessionStore().servers(), isEmpty);

      // A later call succeeds and the data is still there.
      final servers = await SessionStore().servers();
      expect(servers, hasLength(1));
      expect(servers.single.username, 'admin');
    });
  });
}
