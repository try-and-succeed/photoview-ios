import 'package:flutter/widgets.dart';

/// How close to the bottom the user has to be before the next page is asked
/// for, in pixels of unscrolled content.
///
/// Roughly a screenful, so the next page is usually there by the time it is
/// reached, without fetching pages nobody is heading towards.
const loadMoreExtent = 1200.0;

/// Asks for the next page when the scroll position nears the end.
///
/// Replaces asking from inside the item builder. That approach called back for
/// every item built, including ones laid out far below the viewport, so a
/// library of any size paginated itself to the very end **without the user
/// scrolling at all** — measured on a 2 200-album test server: fourteen pages,
/// three thousand media and still going, forty-five seconds after launch, with
/// the app sitting untouched on the first screen. Each page rebuilt a timeline
/// that had grown by another sixty groups, and the main thread never came back
/// up for air; Android eventually killed the frame loop with an ANR.
///
/// Scroll position is the honest signal: it is what "the user is near the end"
/// actually means.
class LoadMoreOnScroll extends StatelessWidget {
  final Widget child;

  /// Called when the end comes within [loadMoreExtent]. Expected to be cheap
  /// and to ignore calls it cannot serve — it fires on many scroll updates.
  final VoidCallback onLoadMore;

  /// False once everything is loaded, so a list at rest stops asking.
  final bool hasMore;

  const LoadMoreOnScroll({
    super.key,
    required this.child,
    required this.onLoadMore,
    this.hasMore = true,
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      // Fires when the extent changes without scrolling, which covers the case
      // of a first page too short to fill the screen.
      onNotification: (notification) {
        _maybeLoad(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _maybeLoad(notification.metrics);
          return false;
        },
        child: child,
      ),
    );
  }

  void _maybeLoad(ScrollMetrics metrics) {
    if (!hasMore) return;
    if (!metrics.hasContentDimensions) return;
    if (metrics.extentAfter > loadMoreExtent) return;

    onLoadMore();
  }
}
