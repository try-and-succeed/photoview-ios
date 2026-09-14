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

    test('rewriting keeps when an absent feature was first seen absent', () async {
      // Every write stores the whole record, so re-stamping would push the
      // expiry forward each time anything else was written, and a server that
      // gained the feature would never be noticed.
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.albumTree: CapabilityState.unsupported,
        }),
      );

      now = now.add(const Duration(days: 6));
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.albumTree: CapabilityState.unsupported,
          Capability.scanner: CapabilityState.supported,
        }),
      );

      // Two days on, the original seven-day window has closed.
      now = now.add(const Duration(days: 2));
      expect(
        (await s.read(serverA))[Capability.albumTree],
        CapabilityState.unknown,
      );
    });

    test('a newly absent feature is stamped now', () async {
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      now = now.add(const Duration(days: 6));
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.unsupported,
        }),
      );

      now = now.add(const Duration(days: 2));
      expect(
        (await s.read(serverA))[Capability.scanner],
        CapabilityState.unsupported,
        reason: 'its own week has not run out yet',
      );
    });

    test('a miss re-confirmed after expiry lasts another seven days', () async {
      // Same revision, so the old entry is still in storage when the fresh
      // answer is written. Its expired date must not be carried into it.
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.albumTree: CapabilityState.unsupported,
        }),
      );

      now = now.add(capabilityMissDuration + const Duration(days: 1));
      expect(
        (await s.read(serverA))[Capability.albumTree],
        CapabilityState.unknown,
        reason: 'expired, so the app probes again',
      );

      // The probe gets the same answer.
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.albumTree: CapabilityState.unsupported,
        }),
      );

      now = now.add(const Duration(days: 6));
      expect(
        (await s.read(serverA))[Capability.albumTree],
        CapabilityState.unsupported,
        reason: 'the fresh answer must last its own seven days',
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

    test('a re-confirmed miss is dated now, not by the old revision', () async {
      // read() throws an entry away when the revision has moved on, because
      // the app is now asking a different question. Carrying that entry's
      // timestamps into the answer to the new question would date the new
      // finding to when the old one was made — and an old enough stamp makes
      // it expire the moment it is written, so the probe runs again on every
      // single launch.
      final s = store();
      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.unsupported,
        }),
      );

      // A release that changed the probes, long after that answer was given.
      final raw = await FlutterSecureStorage().read(key: 'server-capabilities');
      await FlutterSecureStorage().write(
        key: 'server-capabilities',
        value: raw!.replaceAll(
          '"revision":$capabilityProbeRevision',
          '"revision":${capabilityProbeRevision - 1}',
        ),
      );
      now = now.add(const Duration(days: 30));

      // The new probe asks again and gets the same answer.
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.unsupported,
        }),
      );

      expect(
        (await store().read(serverA))[Capability.scanner],
        CapabilityState.unsupported,
        reason: 'the fresh answer must last its own seven days',
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

    test('changes made at the same time do not overwrite each other', () async {
      // Two features downgraded at once — the scanner and the search limit
      // can both fail in the same moment. Each reads the shared record,
      // changes its own feature and writes it back.
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
          Capability.albumTree: CapabilityState.supported,
        }),
      );

      await Future.wait([
        store().update(serverA, (c) => c.downgrade(Capability.scanner)),
        store().update(serverA, (c) => c.downgrade(Capability.albumTree)),
      ]);

      final remembered = await store().read(serverA);
      expect(remembered[Capability.scanner], CapabilityState.unsupported);
      expect(remembered[Capability.albumTree], CapabilityState.unsupported);
    });

    test('a clear is not undone by a write that started earlier', () async {
      await store().write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );

      await Future.wait([
        store().update(serverA, (c) => c.downgrade(Capability.albumTree)),
        store().clear(serverA),
      ]);

      expect(
        (await store().read(serverA)).unresolved,
        containsAll(Capability.values),
      );
    });

    test('a failed change does not block the ones after it', () async {
      final s = store();

      await expectLater(
        s.update(serverA, (_) => throw StateError('boom')),
        throwsStateError,
      );

      await s.write(
        serverA,
        const ServerCapabilities({
          Capability.scanner: CapabilityState.supported,
        }),
      );
      expect(
        (await s.read(serverA))[Capability.scanner],
        CapabilityState.supported,
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
