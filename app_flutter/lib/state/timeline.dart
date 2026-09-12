import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth.dart';

const _pageSize = 200;

/// How close to the end of the loaded media the user must scroll before the
/// next page is requested.
const timelinePrefetchThreshold = 20;

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

class TimelineNotifier extends AsyncNotifier<TimelineData> {
  final List<TimelineMedia> _loaded = [];

  @override
  Future<TimelineData> build() async {
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

    state = AsyncData(current.copyWith(loadingMore: true));

    try {
      final page = await ref.guardedRead(
        (c) => c.timeline(limit: _pageSize, offset: _loaded.length),
      );
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
      state = AsyncError(error, stack);
    }
  }

}

final timelineProvider = AsyncNotifierProvider<TimelineNotifier, TimelineData>(
  TimelineNotifier.new,
);
