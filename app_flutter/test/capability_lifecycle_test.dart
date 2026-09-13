import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/capability_store.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
import 'package:photoview/state/search_limit.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// A client that behaves like a server without the preference field.
class _ServerWithoutPreference extends PhotoviewClient {
  _ServerWithoutPreference() : super(_session);

  @override
  Future<UserPreferences> userPreferences() async =>
      throw UnsupportedFieldException(
        field: 'searchResultLimit',
        type: 'UserPreferences',
      );

  @override
  Future<UserPreferences> changeUserPreferences({
    String? language,
    int? searchResultLimit,
  }) async => throw UnsupportedFieldException(
    field: 'searchResultLimit',
    type: 'UserPreferences',
  );
}

/// A client that answers normally.
class _ServerWithPreference extends PhotoviewClient {
  _ServerWithPreference() : super(_session);

  int? stored = 25;
  String? language = 'English';

  @override
  Future<UserPreferences> userPreferences() async =>
      UserPreferences(language: language, searchResultLimit: stored);

  @override
  Future<UserPreferences> changeUserPreferences({
    String? language,
    int? searchResultLimit,
  }) async {
    this.language = language;
    stored = searchResultLimit;
    return UserPreferences(language: language, searchResultLimit: stored);
  }
}

ProviderContainer _containerWith(PhotoviewClient client) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_FixedAuth.new),
      clientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('searchLimitProvider against a server that lost the preference', () {
    /// Sets up the state that makes this case reachable: the cache says the
    /// server can store the limit, and the server disagrees.
    Future<ProviderContainer> staleSupported(PhotoviewClient client) async {
      await CapabilityStore().write(
        _session.serverId,
        const ServerCapabilities({
          Capability.searchLimitPreference: CapabilityState.supported,
        }),
      );

      final container = _containerWith(client);
      await container.read(authProvider.future);
      await container.read(serverCapabilitiesProvider.future);
      return container;
    }

    test('falls back to the device instead of failing the read', () async {
      // searchProvider awaits this, so throwing here would break searching
      // altogether over a setting.
      final container = await staleSupported(_ServerWithoutPreference());

      final limit = await container.read(searchLimitProvider.future);

      expect(limit.source, SearchLimitSource.device);
      expect(limit.value, isNull);
    });

    test('records the correction so it stops asking the server', () async {
      final container = await staleSupported(_ServerWithoutPreference());

      await container.read(searchLimitProvider.future);

      final corrected = await CapabilityStore().read(_session.serverId);
      expect(
        corrected[Capability.searchLimitPreference],
        CapabilityState.unsupported,
      );
    });

    test('saving still works, on the device', () async {
      final container = await staleSupported(_ServerWithoutPreference());

      await container.read(setSearchLimitProvider)(15);

      expect(
        await SettingsStore().searchResultLimit(_session.serverId),
        15,
      );
    });
  });

  group('searchLimitProvider against a server that has the preference', () {
    Future<ProviderContainer> supported(PhotoviewClient client) async {
      await CapabilityStore().write(
        _session.serverId,
        const ServerCapabilities({
          Capability.searchLimitPreference: CapabilityState.supported,
        }),
      );

      final container = _containerWith(client);
      await container.read(authProvider.future);
      await container.read(serverCapabilitiesProvider.future);
      return container;
    }

    test('reads the value from the server', () async {
      final container = await supported(_ServerWithPreference());

      final limit = await container.read(searchLimitProvider.future);

      expect(limit.source, SearchLimitSource.server);
      expect(limit.value, 25);
    });

    test('writing keeps the language the user picked elsewhere', () async {
      // The mutation replaces the record, so a write that sends only the limit
      // erases the language. This is the regression guard for that.
      final client = _ServerWithPreference();
      final container = await supported(client);

      await container.read(setSearchLimitProvider)(40);

      expect(client.stored, 40);
      expect(client.language, 'English');
    });

    test('an over-large value is clamped rather than stored as given', () async {
      final client = _ServerWithPreference();
      final container = await supported(client);

      await container.read(setSearchLimitProvider)(maxSearchResultLimit + 500);

      expect(client.stored, maxSearchResultLimit);
    });

    test('clearing sends null, not a negative number', () async {
      // The server refuses a negative limit outright, so null is the only way
      // to clear it.
      final client = _ServerWithPreference();
      final container = await supported(client);

      await container.read(setSearchLimitProvider)(null);

      expect(client.stored, isNull);
      expect(client.language, 'English');
    });
  });

  group('capabilityProvider', () {
    test('reports unknown before any answer has arrived', () async {
      final container = _containerWith(_ServerWithPreference());
      await container.read(authProvider.future);

      expect(
        container.read(capabilityProvider(Capability.scanner)),
        CapabilityState.unknown,
      );
      expect(
        container.read(hasCapabilityProvider(Capability.scanner)),
        isFalse,
      );
    });

    test('does not hand out the previous answer during a reload', () async {
      // The case that matters: this provider is keyed on the capability, not
      // on the server, and a reload keeps the previous value readable. Without
      // a guard, switching to a server that lacks a feature would keep
      // offering it until the new probe lands — and offering a feature that is
      // not there is worse than hiding one that is.
      await CapabilityStore().write(
        _session.serverId,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      final container = _containerWith(_ServerWithPreference());
      await container.read(authProvider.future);
      await container.read(serverCapabilitiesProvider.future);

      expect(
        container.read(capabilityProvider(Capability.scanner)),
        CapabilityState.supported,
        reason: 'precondition: the answer is known and cached',
      );

      // Stand-in for what a server switch does to this provider.
      container.invalidate(serverCapabilitiesProvider);

      expect(
        container.read(capabilityProvider(Capability.scanner)),
        CapabilityState.unknown,
      );
      expect(
        container.read(hasCapabilityProvider(Capability.scanner)),
        isFalse,
      );
    });

    test('reports the answer once it has arrived', () async {
      await CapabilityStore().write(
        _session.serverId,
        const ServerCapabilities({
          Capability.searchLimitPreference: CapabilityState.supported,
          Capability.scanner: CapabilityState.unsupported,
        }),
      );

      final container = _containerWith(_ServerWithPreference());
      await container.read(authProvider.future);
      await container.read(serverCapabilitiesProvider.future);

      expect(
        container.read(capabilityProvider(Capability.searchLimitPreference)),
        CapabilityState.supported,
      );
      expect(
        container.read(capabilityProvider(Capability.scanner)),
        CapabilityState.unsupported,
      );
    });
  });
}
