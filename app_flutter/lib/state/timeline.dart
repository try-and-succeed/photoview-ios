import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth.dart';
import 'stale_response_guard.dart';

const _pageSize = 200;

/// The day the timeline starts at, or null for the newest media.
///
/// Held apart from the timeline itself so that choosing a day rebuilds it from
/// that day: the pages are counted from wherever the timeline begins, and an
/// offset into the old list means nothing in the new one.
final timelineFromDayProvider = StateProvider<DateTime?>((ref) => null);

/// The instant handed to the server for [day].
///
/// The filter is `date_shot < fromDate`, so the bound is the start of the day
/// after: anything else would cut the chosen day in half and start with the
/// day before it.
DateTime? timelineBoundFor(DateTime? day) => day == null
    ? null
    : DateTime(day.year, day.month, day.day).add(const Duration(days: 1));


class TimelineData {
  final List<TimelineGroup> groups;
  final int mediaCount;
  final bool hasMore;
  final bool loadingMore;

  const TimelineData({
    this.groups = const [],
    this.mediaCount = 0,
    this.hasMore = true,
    this.loadingMore = false,
  });

  TimelineData copyWith({
    List<TimelineGroup>? groups,
    int? mediaCount,
    bool? hasMore,
    bool? loadingMore,
  }) => TimelineData(
    groups: groups ?? this.groups,
    mediaCount: mediaCount ?? this.mediaCount,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// Collapses the flat timeline into runs of consecutive media that share an
/// album and a calendar day, the way the server already orders them.
List<TimelineGroup> groupTimeline(List<TimelineMedia> items) {
  final groups = <TimelineGroup>[];

  for (final item in items) {
    final day = DateTime(item.date.year, item.date.month, item.date.day);
    final current = groups.isEmpty ? null : groups.last;

    if (current != null &&
        current.albumId == item.albumId &&
        current.day == day) {
      current.media.add(item.media);
    } else {
      groups.add(
        TimelineGroup(
          albumId: item.albumId,
          albumTitle: item.albumTitle,
          day: day,
          media: [item.media],
        ),
      );
    }
  }

  return groups;
}

class TimelineNotifier extends AsyncNotifier<TimelineData>
    with StaleResponseGuard {
  final List<TimelineMedia> _loaded = [];

  @override
  Future<TimelineData> build() async {
    beginGeneration(ref);
    final generation = this.generation;

    // Watched, so choosing another day rebuilds the timeline from there.
    // Before the first await, as every watch in a provider must be.
    final bound = timelineBoundFor(ref.watch(timelineFromDayProvider));

    _loaded.clear();
    final page = await ref.guarded(
      (c) => c.timeline(limit: _pageSize, offset: 0, fromDate: bound),
    );

    // Same check as in loadMore, for the same reason: the notifier outlives a
    // rebuild, so a first page that lands after the next build has cleared
    // _loaded would be appended to that build's timeline. Riverpod ignores
    // what a superseded build returns, so returning the page alone is harmless.
    if (movedOn(generation)) {
      return TimelineData(
        groups: groupTimeline(page),
        mediaCount: page.length,
        hasMore: page.length >= _pageSize,
      );
    }
    _loaded.addAll(page);

    return TimelineData(
      groups: groupTimeline(_loaded),
      mediaCount: _loaded.length,
      hasMore: page.length >= _pageSize,
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    final generation = this.generation;
    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await ref.guardedRead(
        (c) => c.timeline(
          limit: _pageSize,
          offset: _loaded.length,
          // Read rather than watched: this runs from a scroll, not a build,
          // and the day in force is the one this list was built from.
          fromDate: timelineBoundFor(ref.read(timelineFromDayProvider)),
        ),
      );

      // Checked before touching _loaded, not just before the state write: a
      // late page appended here would corrupt the accumulated timeline even if
      // the state assignment were skipped.
      if (movedOn(generation)) return;
      _loaded.addAll(page);

      state = AsyncData(
        TimelineData(
          groups: groupTimeline(_loaded),
          mediaCount: _loaded.length,
          hasMore: page.length >= _pageSize,
          loadingMore: false,
        ),
      );
    } catch (error, stack) {
      if (movedOn(generation)) return;
      state = AsyncError(error, stack);
    }
  }

}

final timelineProvider = AsyncNotifierProvider<TimelineNotifier, TimelineData>(
  TimelineNotifier.new,
);
