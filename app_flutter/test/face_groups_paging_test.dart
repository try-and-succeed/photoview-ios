import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/state/people_order.dart';
import 'package:photoview/state/search_limit.dart' show settingsStoreProvider;

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

class _MemorySettings extends SettingsStore {
  _MemorySettings(this.order);

  String? order;

  @override
  Future<String?> peopleOrder() async => order;

  @override
  Future<void> setPeopleOrder(String? value) async => order = value;
}

/// Answers like the server: every named person first, then the unnamed, in
/// pages of whatever size is asked for.
class _PagingClient extends PhotoviewClient {
  _PagingClient({
    required this.named,
    required this.unnamed,
    this.knowsCountDirection = true,
  }) : super(_session);

  final int named;
  final int unnamed;

  /// False for a server from before `countDirection`, which rejects it.
  final bool knowsCountDirection;

  final requests = <int>[];
  final directions = <bool>[];

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
  }) async {
    if (fewestFirst && !knowsCountDirection) {
      throw UnsupportedFieldException(field: 'countDirection');
    }

    requests.add(offset);
    directions.add(fewestFirst);

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

ProviderContainer _container(
  _PagingClient client, {
  PeopleOrder? order,
  CapabilityState countDirection = CapabilityState.unknown,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_FixedAuth.new),
      clientProvider.overrideWithValue(client),
      settingsStoreProvider.overrideWithValue(_MemorySettings(order?.name)),
      serverCapabilitiesProvider.overrideWith(
        (ref) async => ServerCapabilities({
          Capability.faceGroupCountDirection: countDirection,
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<FaceGroupsData> _load(
  _PagingClient client, {
  PeopleOrder? order,
  CapabilityState countDirection = CapabilityState.unknown,
}) async {
  final container = _container(
    client,
    order: order,
    countDirection: countDirection,
  );

  await _settled(container);
  return container.read(faceGroupsProvider.future);
}

/// Waits for what the people's order depends on, as it has long since
/// arrived by the time someone opens the People tab.
Future<void> _settled(ProviderContainer container) async {
  await container.read(authProvider.future);
  await container.read(peopleOrderProvider.future);
  await container.read(serverCapabilitiesProvider.future);
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

  test(
    'a library of nothing but named people ends without asking forever',
    () async {
      final client = _PagingClient(named: 50, unnamed: 0);

      final data = await _load(client);

      expect(client.requests, [0, 40]);
      expect(data.groups, hasLength(50));
      expect(data.hasMore, isFalse);
    },
  );

  test('no people at all is one request', () async {
    final client = _PagingClient(named: 0, unnamed: 0);

    final data = await _load(client);

    expect(client.requests, [0]);
    expect(data.groups, isEmpty);
    expect(data.hasMore, isFalse);
  });

  group('fewest photos first', () {
    test('is asked of a server that can page that way', () async {
      final client = _PagingClient(named: 95, unnamed: 200);

      final data = await _load(
        client,
        order: PeopleOrder.countAscending,
        countDirection: CapabilityState.supported,
      );

      expect(client.directions, [true, true, true], reason: 'every page');
      expect(data.fewestFirst, isTrue);
    });

    test('and for the pages loaded later as well', () async {
      final client = _PagingClient(named: 3, unnamed: 200);
      final container = _container(
        client,
        order: PeopleOrder.countAscending,
        countDirection: CapabilityState.supported,
      );
      await _settled(container);
      await container.read(faceGroupsProvider.future);

      await container.read(faceGroupsProvider.notifier).loadMore();

      expect(client.requests, [0, 40]);
      expect(client.directions, [true, true]);
      expect(container.read(faceGroupsProvider).value!.fewestFirst, isTrue);
    });

    test('is not asked of a server without countDirection', () async {
      // It would reject the whole request for naming the argument.
      final client = _PagingClient(named: 3, unnamed: 10);

      for (final state in [
        CapabilityState.unsupported,
        CapabilityState.unknown,
      ]) {
        final data = await _load(
          client,
          order: PeopleOrder.countAscending,
          countDirection: state,
        );

        expect(data.fewestFirst, isFalse, reason: state.name);
      }
      expect(client.directions, everyElement(isFalse));
    });

    test('is not asked for under any other order', () async {
      final client = _PagingClient(named: 3, unnamed: 10);

      for (final order in PeopleOrder.values.where(
        (o) => o != PeopleOrder.countAscending,
      )) {
        final data = await _load(
          client,
          order: order,
          countDirection: CapabilityState.supported,
        );

        expect(data.fewestFirst, isFalse, reason: order.name);
      }
      expect(client.directions, everyElement(isFalse));
    });

    test('choosing it fetches again; A to Z and Z to A do not', () async {
      final client = _PagingClient(named: 3, unnamed: 10);
      final container = _container(
        client,
        order: PeopleOrder.nameAscending,
        countDirection: CapabilityState.supported,
      );
      await _settled(container);
      // Kept alive the way the people screen keeps it, by listening.
      container.listen(faceGroupsProvider, (_, _) {});
      await container.read(faceGroupsProvider.future);
      final notifier = container.read(peopleOrderProvider.notifier);

      await notifier.choose(PeopleOrder.nameDescending);
      await container.read(faceGroupsProvider.future);
      expect(client.requests, [0], reason: 'the same pages, re-sorted');

      await notifier.choose(PeopleOrder.countAscending);
      final data = await container.read(faceGroupsProvider.future);
      expect(client.directions, [false, true]);
      expect(data.fewestFirst, isTrue);
    });

    test('an answer that arrives late fetches the people again', () async {
      // Most first meanwhile rather than waiting: a setting that cannot be
      // read must not keep the people from showing.
      final client = _PagingClient(named: 3, unnamed: 10);
      final container = _container(
        client,
        order: PeopleOrder.countAscending,
        countDirection: CapabilityState.supported,
      );
      await container.read(authProvider.future);
      container.listen(faceGroupsProvider, (_, _) {});

      final early = await container.read(faceGroupsProvider.future);
      expect(early.fewestFirst, isFalse);

      await _settled(container);
      final data = await container.read(faceGroupsProvider.future);

      expect(client.directions, [false, true]);
      expect(data.fewestFirst, isTrue);
    });

    test('a server that turns out not to have it gets most first', () async {
      // The cache said yes and the server says no — rolled back, most likely.
      // An error screen over a sort order would be the wrong answer.
      final client = _PagingClient(
        named: 3,
        unnamed: 10,
        knowsCountDirection: false,
      );

      final data = await _load(
        client,
        order: PeopleOrder.countAscending,
        countDirection: CapabilityState.supported,
      );

      expect(data.groups, hasLength(13));
      expect(data.fewestFirst, isFalse);
      expect(client.directions, [false]);
    });
  });
}
