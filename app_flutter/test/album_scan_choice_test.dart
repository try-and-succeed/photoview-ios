import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/album_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

/// A year album, and a record of every scan asked for.
class _ScanClient extends PhotoviewClient {
  _ScanClient() : super(_session);

  final scans = <({String albumId, bool onlyNew})>[];

  @override
  Future<List<ScannerJob>> scannerQueue() async => const [];

  @override
  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async => const AlbumPage(title: '2026', media: [], subAlbums: []);

  @override
  Future<String?> scanAlbum(
    String albumId, {
    bool onlyNewSubAlbums = false,
  }) async {
    scans.add((albumId: albumId, onlyNew: onlyNewSubAlbums));
    return 'Scanner started';
  }
}

Override _capabilities({required bool onlyNew}) =>
    serverCapabilitiesProvider.overrideWith(
      (ref) async => ServerCapabilities({
        Capability.scanner: CapabilityState.supported,
        Capability.scanAlbumNewSubAlbums: onlyNew
            ? CapabilityState.supported
            : CapabilityState.unsupported,
      }),
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late _ScanClient client;

  Future<void> open(WidgetTester tester, {required bool onlyNew}) async {
    client = _ScanClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
          _capabilities(onlyNew: onlyNew),
        ],
        child: localizedApp(
          home: const AlbumScreen(albumId: '4', title: '2026'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapScan(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Scan for new media'));
    await tester.pumpAndSettle();
  }

  testWidgets('"only what is new" sends the quick scan', (tester) async {
    await open(tester, onlyNew: true);
    await tapScan(tester);

    await tester.tap(find.text('Only what is new'));
    await tester.pumpAndSettle();

    expect(client.scans, [(albumId: '4', onlyNew: true)]);
    expect(
      find.text('Scanning this album and its new folders.'),
      findsOneWidget,
    );
  });

  testWidgets('"everything" sends the full scan', (tester) async {
    await open(tester, onlyNew: true);
    await tapScan(tester);

    await tester.tap(find.text('Everything'));
    await tester.pumpAndSettle();

    expect(client.scans, [(albumId: '4', onlyNew: false)]);
    expect(
      find.text('Scanning this album and its sub-albums.'),
      findsOneWidget,
    );
  });

  testWidgets('cancel scans nothing', (tester) async {
    await open(tester, onlyNew: true);
    await tapScan(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(client.scans, isEmpty);
  });

  testWidgets('a server without the choice scans everything at once', (
    tester,
  ) async {
    await open(tester, onlyNew: false);
    await tapScan(tester);

    expect(find.text('Only what is new'), findsNothing);
    expect(client.scans, [(albumId: '4', onlyNew: false)]);
  });
}
