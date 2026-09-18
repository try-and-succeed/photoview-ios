import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/timeline.dart';

final _session = Session(
  endpoint: Uri.parse('http://host/api/graphql'),
  token: 'tok',
  username: 'admin',
);

TimelineMedia _entry(String id) => TimelineMedia(
  media: MediaItem(id: id, type: MediaType.photo),
  date: DateTime(2026, 5, 1),
  albumId: 'a',
  albumTitle: 'Album',
);

/// Serves timeline pages on demand so a request can be left in flight.
class _ScriptedClient extends PhotoviewClient {
  _ScriptedClient() : super(_session);

  final _pending = <Completer<List<TimelineMedia>>>[];
  int calls = 0;

  @override
  Future<List<TimelineMedia>> timeline({
    required int limit,
    required int offset,
    DateTime? fromDate,
  }) {
    calls++;
    final completer = Completer<List<TimelineMedia>>();
    _pending.add(completer);
    return completer.future;
  }

  /// Answers the oldest outstanding request.
  void answer(List<TimelineMedia> page) => _pending.removeAt(0).complete(page);

  /// Fails the oldest outstanding request.
  void fail(Object error) => _pending.removeAt(0).completeError(error);

  int get outstanding => _pending.length;
}

void main() {
  late _ScriptedClient client;
  late ProviderContainer container;

  setUp(() {
    client = _ScriptedClient();
    container = ProviderContainer(
      overrides: [
        clientProvider.overrideWithValue(client),
        imageCacheCleanerProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<TimelineData> firstPage(List<TimelineMedia> page) async {
    final future = container.read(timelineProvider.future);
    await Future<void>.delayed(Duration.zero);
    client.answer(page);
    return future;
  }

  group('TimelineNotifier pagination guard', () {
    test('appends a page that arrives while still current', () async {
      await firstPage([for (var i = 0; i < 200; i++) _entry('$i')]);

      final notifier = container.read(timelineProvider.notifier);
      final loading = notifier.loadMore();
      await Future<void>.delayed(Duration.zero);
      client.answer([_entry('extra')]);
      await loading;

      expect(container.read(timelineProvider).value!.mediaCount, 201);
    });

    test('discards a page that arrives after a rebuild', () async {
      await firstPage([for (var i = 0; i < 200; i++) _entry('$i')]);

      final notifier = container.read(timelineProvider.notifier);
      final loading = notifier.loadMore();
      await Future<void>.delayed(Duration.zero);
      expect(client.outstanding, 1, reason: 'loadMore is in flight');

      // Pull-to-refresh, a server switch — the provider starts over.
      container.invalidate(timelineProvider);
      final rebuilt = container.read(timelineProvider.future);
      await Future<void>.delayed(Duration.zero);

      // The stale loadMore answers first, then the new build.
      client.answer([_entry('stale')]);
      await loading;
      client.answer([_entry('fresh')]);
      await rebuilt;

      final data = container.read(timelineProvider).value!;
      expect(
        data.mediaCount,
        1,
        reason: 'only the rebuilt page counts; the stale one is dropped',
      );
      expect(data.groups.single.media.single.id, 'fresh');
    });

    test('a first page that arrives after a rebuild is not mixed in', () async {
      // A server switch or a refresh while the timeline is still loading its
      // first page. The rebuild clears the accumulated list; the old build's
      // page must not be appended to it afterwards.
      container.read(timelineProvider.future).ignore();
      await Future<void>.delayed(Duration.zero);
      expect(client.outstanding, 1, reason: 'the first build is in flight');

      container.invalidate(timelineProvider);
      final rebuilt = container.read(timelineProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(client.outstanding, 2, reason: 'the rebuild is in flight too');

      // The old build answers after the rebuild has already started.
      client.answer([_entry('stale')]);
      await Future<void>.delayed(Duration.zero);
      client.answer([_entry('fresh')]);
      await rebuilt;

      final data = container.read(timelineProvider).value!;
      expect(data.mediaCount, 1);
      expect(data.groups.single.media.single.id, 'fresh');
    });

    test('a late failure does not overwrite the rebuilt state', () async {
      await firstPage([for (var i = 0; i < 200; i++) _entry('$i')]);

      final notifier = container.read(timelineProvider.notifier);
      final loading = notifier.loadMore();
      await Future<void>.delayed(Duration.zero);

      container.invalidate(timelineProvider);
      final rebuilt = container.read(timelineProvider.future);
      await Future<void>.delayed(Duration.zero);

      // Two requests are outstanding, oldest first: the abandoned loadMore
      // fails, then the rebuild succeeds.
      client.fail(const ApiException('too late'));
      await loading;
      client.answer([_entry('fresh')]);
      await rebuilt;

      expect(
        container.read(timelineProvider).hasError,
        isFalse,
        reason: 'a dead request must not put the screen into an error state',
      );
    });
  });
}
