import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

class _CountingClient extends PhotoviewClient {
  _CountingClient() : super(_session);

  /// Which people were asked about, in order.
  final personReads = <String>[];

  @override
  Future<List<MediaItem>> personMedia(String faceGroupId) async {
    personReads.add(faceGroupId);
    return const [];
  }

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
  }) async => const [];

  @override
  Future<int> recognizeUnlabeledFaces() async => 3;

  @override
  Future<String?> combineFaceGroups(
    String destinationFaceGroupId,
    List<String> sourceFaceGroupIds,
  ) async => 'Regina';
}

Future<ProviderContainer> _container(_CountingClient client) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_FixedAuth.new),
      clientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);

  await container.read(authProvider.future);
  return container;
}

void main() {
  test('a match against the named people drops every person list', () async {
    // The server decides which people grew, and the answer does not say which.
    // A person screen left open would otherwise show the photos it read before
    // the match for as long as it stays open.
    final client = _CountingClient();
    final container = await _container(client);

    await container.read(personMediaProvider('7').future);
    await container.read(personMediaProvider('8').future);
    expect(client.personReads, ['7', '8']);

    await container.read(faceActionsProvider).recognizeUnlabeled();

    // `invalidate` rebuilds on the next read, so reading is the proof.
    await container.read(personMediaProvider('7').future);
    await container.read(personMediaProvider('8').future);

    expect(client.personReads, ['7', '8', '7', '8']);
  });

  test('a merge drops the list of the person that grew', () async {
    final client = _CountingClient();
    final container = await _container(client);

    await container.read(personMediaProvider('7').future);
    await container.read(faceActionsProvider).merge('7', ['9']);
    await container.read(personMediaProvider('7').future);

    expect(client.personReads, ['7', '7']);
  });
}
