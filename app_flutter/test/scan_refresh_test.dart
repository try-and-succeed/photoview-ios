import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
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

/// A server whose library changes under the app, as it does when a file is
/// deleted on disk and the album is scanned again.
class _ScanningClient extends PhotoviewClient {
  _ScanningClient() : super(_session);

  List<ScannerJob> queue = [];
  int albumReads = 0;
  int albumListReads = 0;

  /// What the album holds, replaced when the scan "finds" the deletion.
  List<MediaItem> media = const [
    MediaItem(id: '1', type: MediaType.photo, title: 'kept.jpg'),
    MediaItem(id: '2', type: MediaType.photo, title: 'deleted.jpg'),
  ];

  @override
  Future<List<ScannerJob>> scannerQueue() async => queue;

  @override
  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async {
    albumReads++;
    return AlbumPage(title: 'Urlaub', media: media, subAlbums: const []);
  }

  @override
  Future<List<AlbumItem>> myAlbums() async {
    albumListReads++;
    return const [AlbumItem(id: '7', title: 'Urlaub')];
  }

  @override
  Future<String?> scanAlbum(String albumId) async => 'Scanner started';
}

void main() {
  // The notifier installs an AppLifecycleListener, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late _ScanningClient client;
  late ProviderContainer container;

  Future<void> open({List<ScannerJob> queue = const []}) async {
    client = _ScanningClient()..queue = queue;
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authProvider.future);
  }

  test('a finished scan drops what the album had read before it', () async {
    // The bug: a file deleted on disk stayed on screen until the user signed
    // out. Nothing ever asked the server again, though the server had it
    // right from the moment the album was scanned.
    await open(queue: [ScannerJob(albumId: '7', albumTitle: 'Urlaub', status: ScannerJobStatus.running)]);

    container.listen(scannerProvider, (_, _) {});

    // The first poll has to have landed: a refresh that overtakes it would
    // see an empty queue as the state before, and find nothing to react to.
    await pumpEventQueue();
    expect(container.read(scannerProvider).jobs, hasLength(1));

    final album = await container.read(albumProvider('7').future);
    await container.read(myAlbumsProvider.future);

    expect(album.media.map((m) => m.title), ['kept.jpg', 'deleted.jpg']);
    expect(client.albumReads, 1);

    // The scan ends, and with it goes the deleted file.
    client
      ..queue = []
      ..media = const [MediaItem(id: '1', type: MediaType.photo, title: 'kept.jpg')];

    await container.read(scannerProvider.notifier).refresh();
    await pumpEventQueue();

    // Both were dropped, so reading them asks the server again — which is
    // what the screens showing them do on their next build.
    final after = await container.read(albumProvider('7').future);
    expect(after.media.map((m) => m.title), ['kept.jpg']);
    expect(client.albumReads, 2, reason: 'the album was read again');

    await container.read(myAlbumsProvider.future);
    expect(client.albumListReads, 2, reason: 'so was the album list');
  });

  test('a queue that was empty all along re-reads nothing', () async {
    // Every poll must not throw the library away: the queue is empty most of
    // the time, and the scanner screen polls while it is open.
    await open();

    container.listen(scannerProvider, (_, _) {});
    await container.read(albumProvider('7').future);
    final reads = client.albumReads;

    await container.read(scannerProvider.notifier).refresh();
    await pumpEventQueue();

    expect(client.albumReads, reads);
  });

  test('a scan started without a listener is followed to its end', () async {
    // The album screen starts a scan with a bare `ref.read`, which leaves
    // nobody watching. Without holding the notifier alive, it is disposed as
    // soon as the request comes back, polling stops, and the end of the scan —
    // the moment the library goes out of date — is never noticed.
    await open(queue: [ScannerJob(albumId: '7', albumTitle: 'Urlaub', status: ScannerJobStatus.running)]);

    await container.read(albumProvider('7').future);
    await container.read(scannerProvider.notifier).scanAlbum('7');
    await pumpEventQueue();

    client
      ..queue = []
      ..media = const [MediaItem(id: '1', type: MediaType.photo, title: 'kept.jpg')];

    // One poll interval later the queue is empty, and the album is dropped.
    // Dropped, not refetched: nothing is watching it, so the next read is
    // what asks the server again — which is what the album screen does when
    // the user comes back to it.
    await Future<void>.delayed(scannerPollInterval + const Duration(seconds: 1));
    await pumpEventQueue();

    final after = await container.read(albumProvider('7').future);
    expect(after.media.map((m) => m.title), ['kept.jpg']);
    expect(client.albumReads, 2, reason: 'read once before, once after');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
