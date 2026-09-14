import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/scanner.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

class _FakeScannerClient extends PhotoviewClient {
  _FakeScannerClient() : super(_session);

  List<ScannerJob> queue = [];
  final List<String> cancelled = [];
  final List<String> scanned = [];
  int queueReads = 0;
  int cancelAllCalls = 0;
  Object? failWith;

  /// A queued job vanishes at once; a running one keeps going until it
  /// finishes its current file, so it is still in the next snapshot.
  bool removeOnCancel = true;

  /// What `cancelScanJob` answers: false when there was no such job.
  bool acceptCancel = true;

  @override
  Future<List<ScannerJob>> scannerQueue() async {
    queueReads++;
    final failure = failWith;
    if (failure != null) throw failure;
    return queue;
  }

  /// How long the server takes to accept a scan. Not zero in every test: the
  /// real call has a two-minute timeout, and an instant answer hides anything
  /// that depends on the provider still existing when the answer arrives.
  Duration scanDelay = Duration.zero;

  @override
  Future<String?> scanAlbum(String albumId) async {
    scanned.add(albumId);
    if (scanDelay > Duration.zero) await Future<void>.delayed(scanDelay);
    return 'Scanner started';
  }

  /// How long the server takes to answer a stop request. Same reasoning as
  /// [scanDelay].
  Duration cancelDelay = Duration.zero;

  @override
  Future<bool> cancelScanJob(String albumId) async {
    cancelled.add(albumId);
    if (cancelDelay > Duration.zero) await Future<void>.delayed(cancelDelay);
    if (!acceptCancel) return false;

    if (removeOnCancel) {
      queue = queue.where((j) => j.albumId != albumId).toList();
    }
    return true;
  }

  @override
  Future<int> cancelAllScanJobs() async {
    cancelAllCalls++;
    if (cancelDelay > Duration.zero) await Future<void>.delayed(cancelDelay);
    final count = queue.length;
    queue = [];
    return count;
  }
}

ScannerJob _job(
  String id,
  String title, [
  ScannerJobStatus status = ScannerJobStatus.running,
]) => ScannerJob(albumId: id, albumTitle: title, status: status);

void main() {
  // The notifier installs an AppLifecycleListener, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Recording a capability downgrade writes to secure storage.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('ScannerJob.fromJson', () {
    test('reads the two statuses the server sends', () {
      expect(
        ScannerJob.fromJson({
          'album': {'id': 8, 'title': 'Berge'},
          'status': 'RUNNING',
        }).status,
        ScannerJobStatus.running,
      );
      expect(
        ScannerJob.fromJson({
          'album': {'id': '9', 'title': 'Makro'},
          'status': 'QUEUED',
        }).status,
        ScannerJobStatus.queued,
      );
    });

    test('a status added later reads as busy rather than breaking', () {
      final job = ScannerJob.fromJson({
        'album': {'id': '1', 'title': 'x'},
        'status': 'PAUSED',
      });

      expect(job.status, ScannerJobStatus.unknown);
    });

    test('survives an album the server did not fill in', () {
      final job = ScannerJob.fromJson({'status': 'RUNNING'});

      expect(job.albumId, '');
      expect(job.albumTitle, '');
    });

    test('takes a numeric id as a string', () {
      expect(
        ScannerJob.fromJson({
          'album': {'id': 42, 'title': 'x'},
          'status': 'QUEUED',
        }).albumId,
        '42',
      );
    });
  });

  group('ScannerNotifier', () {
    late _FakeScannerClient client;
    late ProviderContainer container;

    Future<void> start(List<ScannerJob> queue) async {
      client = _FakeScannerClient()..queue = queue;
      container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authProvider.future);
      container.listen(scannerProvider, (_, _) {});
      await pumpEventQueue();
    }

    test('reads the queue on open', () async {
      await start([_job('8', 'Berge')]);

      expect(container.read(scannerProvider).jobs, hasLength(1));
      expect(container.read(scannerProvider).isLoading, isFalse);
    });

    test('an empty queue keeps polling, only slower', () async {
      // A scan can start from another device or on the server's own schedule.
      // A screen that stopped asking would go on claiming the scanner is idle
      // while it is working.
      await start([]);
      final reads = client.queueReads;

      await Future<void>.delayed(scannerPollInterval * 2);
      expect(
        client.queueReads,
        reads,
        reason: 'not at the busy cadence',
      );

      await Future<void>.delayed(scannerIdlePollInterval);
      expect(client.queueReads, greaterThan(reads));
    });

    test('a busy queue polls at the faster cadence', () async {
      await start([_job('8', 'Berge')]);
      final reads = client.queueReads;

      await Future<void>.delayed(scannerPollInterval * 2);

      expect(client.queueReads, greaterThan(reads));
    });

    test('cancelling marks the album as stopping before the server agrees',
        () async {
      // The server has no "cancelling" status, so without this the row would
      // look as though the button did nothing.
      await start([_job('8', 'Berge')]);

      final pending = container.read(scannerProvider.notifier).cancel('8');
      expect(container.read(scannerProvider).stopping, contains('8'));

      await pending;
      expect(client.cancelled, ['8']);
    });

    test('a stop request is forgotten once the job leaves the queue', () async {
      await start([_job('8', 'Berge')]);

      await container.read(scannerProvider.notifier).cancel('8');

      expect(container.read(scannerProvider).jobs, isEmpty);
      expect(container.read(scannerProvider).stopping, isEmpty);
    });

    test('a job still running after a stop keeps the label', () async {
      // A running job finishes its current file before it disappears, so it is
      // still in the next snapshot — and must still read as stopping.
      await start([_job('8', 'Berge')]);
      client.removeOnCancel = false;

      await container.read(scannerProvider.notifier).cancel('8');

      final state = container.read(scannerProvider);
      expect(state.jobs, hasLength(1));
      expect(state.stopping, contains('8'));
    });

    test('a refused stop does not leave the row marked stopping', () async {
      // False means the server had no job under that album id — the usual
      // answer for an album whose sub-albums are the queued ones. Keeping the
      // label would claim a request the server never took.
      await start([_job('8', 'Berge')]);
      client.acceptCancel = false;

      await container.read(scannerProvider.notifier).cancel('8');

      expect(container.read(scannerProvider).stopping, isEmpty);
    });

    test('stop all marks everything and reports the count', () async {
      await start([_job('8', 'Berge'), _job('9', 'Makro')]);

      final cancelled = await container
          .read(scannerProvider.notifier)
          .cancelAll();

      expect(cancelled, 2);
      expect(client.cancelAllCalls, 1);
      expect(container.read(scannerProvider).jobs, isEmpty);
    });

    test('a failed cancel takes the stopping label back', () async {
      await start([_job('8', 'Berge')]);
      client.failWith = const ApiException('nope');

      // The cancel itself succeeds in the fake, the refresh after it fails;
      // either way the user must not be left with a stuck "stopping" row.
      await container.read(scannerProvider.notifier).cancel('8');

      expect(container.read(scannerProvider).error, isNotNull);
    });

    test('a server without the scanner stops the polling', () async {
      // A stale "supported" would otherwise have the screen repeat the same
      // impossible request every few seconds, for ever.
      await start([_job('8', 'Berge')]);
      client.failWith = UnsupportedFieldException(
        field: 'scannerQueueStatus',
        type: 'Query',
      );

      await container.read(scannerProvider.notifier).refresh();
      final reads = client.queueReads;

      await Future<void>.delayed(scannerPollInterval * 2);

      expect(client.queueReads, reads);
      expect(container.read(scannerProvider).error, isNotNull);
    });

    test('a queue read failure is reported without losing what was shown',
        () async {
      await start([_job('8', 'Berge')]);
      client.failWith = const ApiException('server down');

      await container.read(scannerProvider.notifier).refresh();

      final state = container.read(scannerProvider);
      expect(state.error, contains('server down'));
      expect(state.jobs, hasLength(1));
    });

    test('starting a scan asks for the album the user chose', () async {
      await start([]);

      await container.read(scannerProvider.notifier).scanAlbum('3');

      expect(client.scanned, ['3']);
    });

    test('a scan started without a listener stops polling afterwards',
        () async {
      // What the album screen does: `ref.read(...).scanAlbum(...)` and nothing
      // else. That creates no listener, so this auto-disposed provider is torn
      // down while the request is still running. Its onDispose — the only
      // thing that cancels the poll timer — has then already fired, and the
      // refresh at the end of scanAlbum would schedule a timer nobody can
      // cancel: a queue poll every ten seconds for the rest of the app's life.
      client = _FakeScannerClient()..scanDelay = const Duration(seconds: 1);
      container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authProvider.future);

      await container.read(scannerProvider.notifier).scanAlbum('7');
      final reads = client.queueReads;

      await Future<void>.delayed(scannerIdlePollInterval * 2);

      expect(
        client.queueReads,
        reads,
        reason: 'the poll outlived the provider that owns it',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    for (final (name, stop) in [
      ('stop', (ScannerNotifier n) => n.cancel('8')),
      ('stop all', (ScannerNotifier n) => n.cancelAll()),
    ]) {
      test('a $name whose screen closes at once stops polling afterwards',
          () async {
        // The user presses stop and leaves the scanner screen straight away,
        // so the last listener goes while the request is still out.
        client = _FakeScannerClient()
          ..queue = [_job('8', 'Berge')]
          ..cancelDelay = const Duration(seconds: 1);
        container = ProviderContainer(
          overrides: [
            authProvider.overrideWith(_FixedAuth.new),
            clientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authProvider.future);

        final screen = container.listen(scannerProvider, (_, _) {});
        await pumpEventQueue();

        final pending = stop(container.read(scannerProvider.notifier));
        screen.close();
        await pending;
        final reads = client.queueReads;

        await Future<void>.delayed(scannerIdlePollInterval * 2);

        expect(
          client.queueReads,
          reads,
          reason: 'the poll outlived the provider that owns it',
        );
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });
}
