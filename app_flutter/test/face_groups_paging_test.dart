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

/// Answers like the server: every named person first, then the unnamed, in
/// pages of whatever size is asked for.
class _PagingClient extends PhotoviewClient {
  _PagingClient({required this.named, required this.unnamed})
    : super(_session);

  final int named;
  final int unnamed;
  final requests = <int>[];

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
  }) async {
    requests.add(offset);

    return [
      for (var i = offset; i < offset + limit && i < named + unnamed; i++)
        FaceGroup(
          id: '$i',
          label: i < named ? 'person $i' : null,
          imageFaceCount: named + unnamed - i,
        ),
    ];
  }
}

Future<FaceGroupsData> _load(_PagingClient client) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_FixedAuth.new),
      clientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);

  await container.read(authProvider.future);
  return container.read(faceGroupsProvider.future);
}

void main() {
  test('one page is enough when the named fit in it', () async {
    final client = _PagingClient(named: 3, unnamed: 10);

    final data = await _load(client);

    expect(client.requests, [0]);
    expect(data.groups, hasLength(13));
  });

  test('it keeps fetching while a page is nothing but named people', () async {
    // The app puts the named ones in its own order, which it can only get
    // right with all of them in hand — a name arriving later would have to
    // slot in above wherever the user has scrolled to.
    final client = _PagingClient(named: 95, unnamed: 200);

    final data = await _load(client);

    expect(client.requests, [0, 40, 80], reason: 'stops at the first unnamed');
    expect(data.groups, hasLength(120));
    expect(data.hasMore, isTrue);
  });

  test('a library of nothing but named people ends without asking forever', () async {
    final client = _PagingClient(named: 50, unnamed: 0);

    final data = await _load(client);

    expect(client.requests, [0, 40]);
    expect(data.groups, hasLength(50));
    expect(data.hasMore, isFalse);
  });

  test('no people at all is one request', () async {
    final client = _PagingClient(named: 0, unnamed: 0);

    final data = await _load(client);

    expect(client.requests, [0]);
    expect(data.groups, isEmpty);
    expect(data.hasMore, isFalse);
  });
}
