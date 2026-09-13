import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth.dart';
import 'stale_response_guard.dart';

const _pageSize = 200;


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

    _loaded.clear();
    final page = await ref.guarded((c) => c.timeline(limit: _pageSize, offset: 0));
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
        (c) => c.timeline(limit: _pageSize, offset: _loaded.length),
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
