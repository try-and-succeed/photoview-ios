import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/timeline.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

/// Records what each timeline request asked for, and answers with media dated
/// just under the bound, the way the server would.
class _RecordingClient extends PhotoviewClient {
  _RecordingClient() : super(_session);

  final asked = <({int offset, DateTime? fromDate})>[];

  @override
  Future<List<TimelineMedia>> timeline({
    required int limit,
    required int offset,
    DateTime? fromDate,
  }) async {
    asked.add((offset: offset, fromDate: fromDate));

    final newest = fromDate ?? DateTime(2026, 9, 18);
    return [
      for (var i = 0; i < 3; i++)
        TimelineMedia(
          media: MediaItem(id: '$offset-$i', type: MediaType.photo),
          date: newest.subtract(Duration(days: offset + i + 1)),
          albumId: '2',
          albumTitle: 'Landscapes',
        ),
    ];
  }
}

ProviderContainer _container(_RecordingClient client) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_FixedAuth.new),
      clientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('timelineBoundFor', () {
    test('asks for the day after, so the chosen day is included', () {
      // The server filters with `date_shot < fromDate`. Handing it the chosen
      // day itself would start the timeline on the day before.
      expect(
        timelineBoundFor(DateTime(2024, 3, 12)),
        DateTime(2024, 3, 13),
      );
    });

    test('drops a time of day, so a day means the whole day', () {
      expect(
        timelineBoundFor(DateTime(2024, 3, 12, 22, 45)),
        DateTime(2024, 3, 13),
      );
    });

    test('crosses the end of a month and a year', () {
      expect(timelineBoundFor(DateTime(2024, 2, 29)), DateTime(2024, 3, 1));
      expect(timelineBoundFor(DateTime(2023, 12, 31)), DateTime(2024, 1, 1));
    });

    test('no day means no bound: the newest media', () {
      expect(timelineBoundFor(null), isNull);
    });
  });

  group('the timeline', () {
    test('starts at the newest until a day is chosen', () async {
      final client = _RecordingClient();
      final container = _container(client);

      await container.read(authProvider.future);
      await container.read(timelineProvider.future);

      expect(client.asked.single.fromDate, isNull);
    });

    test('is rebuilt from the chosen day', () async {
      final client = _RecordingClient();
      final container = _container(client);

      await container.read(authProvider.future);
      await container.read(timelineProvider.future);

      container.read(timelineFromDayProvider.notifier).state = DateTime(
        2024,
        3,
        12,
      );
      await container.read(timelineProvider.future);

      expect(client.asked, hasLength(2));
      expect(client.asked.last.fromDate, DateTime(2024, 3, 13));
      expect(
        client.asked.last.offset,
        0,
        reason: 'an offset into the old list means nothing in the new one',
      );
    });

    test('keeps the day while paging onwards', () async {
      // Without this the second page would come from the newest media and be
      // appended to a list that starts years earlier.
      final client = _RecordingClient();
      final container = _container(client);

      await container.read(authProvider.future);
      container.read(timelineFromDayProvider.notifier).state = DateTime(
        2024,
        3,
        12,
      );
      await container.read(timelineProvider.future);

      await container.read(timelineProvider.notifier).loadMore();

      expect(client.asked.last.fromDate, DateTime(2024, 3, 13));
    });

    test('goes back to the newest when the day is cleared', () async {
      final client = _RecordingClient();
      final container = _container(client);

      await container.read(authProvider.future);
      container.read(timelineFromDayProvider.notifier).state = DateTime(
        2024,
        3,
        12,
      );
      await container.read(timelineProvider.future);

      container.read(timelineFromDayProvider.notifier).state = null;
      await container.read(timelineProvider.future);

      expect(client.asked.last.fromDate, isNull);
    });
  });
}
