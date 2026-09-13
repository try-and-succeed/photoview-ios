import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/capability_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverA = 'http://a/api/graphql|admin';
  const serverB = 'http://b/api/graphql|admin';

  var now = DateTime.utc(2026, 9, 13, 8);
  CapabilityStore store() => CapabilityStore(now: () => now);

  setUp(() {
    now = DateTime.utc(2026, 9, 13, 8);
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('CapabilityStore', () {
    test('remembers nothing for a server never probed', () async {
      final remembered = await store().read(serverA);

      expect(remembered.unresolved, containsAll(Capability.values));
    });

    test('round-trips what was answered', () async {
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
          Capability.albumTree: CapabilityState.unsupported,
        }),
      );

      final remembered = await store().read(serverA);

      expect(remembered[Capability.scanner], CapabilityState.supported);
      expect(remembered[Capability.albumTree], CapabilityState.unsupported);
    });

    test('does not store an unanswered question', () async {
      // Writing "unknown" would make the next launch skip the probe that could
      // finally settle it.
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.unknown,
        }),
      );

      expect(
        (await store().read(serverA)).unresolved,
        contains(Capability.scanner),
      );
    });

    test('keeps servers apart', () async {
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );
      await store().write(
        serverB,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.unsupported,
        }),
      );

      expect(
        (await store().read(serverA))[Capability.scanner],
        CapabilityState.supported,
      );
      expect(
        (await store().read(serverB))[Capability.scanner],
        CapabilityState.unsupported,
      );
    });

    test('a supported answer does not expire', () async {
      // A feature that is present does not go away on its own; re-probing for
      // it every week would be pure cost.
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      now = now.add(const Duration(days: 400));

      expect(
        (await store().read(serverA))[Capability.scanner],
        CapabilityState.supported,
      );
    });

    test('an unsupported answer expires, so a server upgrade is noticed', () async {
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.albumTree: CapabilityState.unsupported,
        }),
      );

      now = now.add(capabilityMissDuration - const Duration(minutes: 1));
      expect(
        (await store().read(serverA))[Capability.albumTree],
        CapabilityState.unsupported,
      );

      now = now.add(const Duration(minutes: 2));
      expect(
        (await store().read(serverA))[Capability.albumTree],
        CapabilityState.unknown,
      );
    });

    test('a changed probe revision discards the entry', () async {
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      // Simulates a release that changed what the probes ask.
      final raw = await FlutterSecureStorage().read(key: 'server-capabilities');
      await FlutterSecureStorage().write(
        key: 'server-capabilities',
        value: raw!.replaceAll(
          '"revision":$capabilityProbeRevision',
          '"revision":${capabilityProbeRevision + 1}',
        ),
      );

      expect(
        (await store().read(serverA)).unresolved,
        contains(Capability.scanner),
      );
    });

    test('clear forgets one server and keeps the others', () async {
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );
      await s.write(
        serverB,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      await s.clear(serverA);

      expect((await s.read(serverA)).unresolved, contains(Capability.scanner));
      expect(
        (await s.read(serverB))[Capability.scanner],
        CapabilityState.supported,
      );
    });

    test('a downgrade survives a restart', () async {
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      final corrected = (await s.read(serverA)).downgrade(Capability.scanner);
      await s.write(serverA, corrected);

      expect(
        (await store().read(serverA))[Capability.scanner],
        CapabilityState.unsupported,
      );
    });

    test('unreadable storage reports nothing rather than throwing', () async {
      FlutterSecureStorage.setMockInitialValues({
        'server-capabilities': 'not json at all',
      });

      expect(
        (await store().read(serverA)).unresolved,
        containsAll(Capability.values),
      );
    });
  });
}
