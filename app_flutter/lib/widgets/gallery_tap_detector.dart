import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Reports single taps on [child] from the raw pointer events, whoever wins
/// the gesture.
///
/// The photo view's own tap is lost on a zoomed photo: there it takes the
/// gesture for panning on the very first move of a finger, without any slop
/// (`PhotoViewGestureRecognizer._decideIfWeAcceptEvent`), and a fingertip
/// always moves a pixel or two while tapping. A face on a zoomed photo could
/// not be tapped on a phone, only with a tap that does not move at all.
///
/// Watching the pointers sees every tap whatever the arena decides. A tap
/// here is one finger, moved less than the touch slop, lifted within the
/// long-press time — and not followed by a second one within the double-tap
/// time, since a double tap zooms and must not also count as a tap.
class GalleryTapDetector extends StatefulWidget {
  /// Called with where the tap landed, in global coordinates.
  final void Function(Offset globalPosition) onTap;

  final Widget child;

  const GalleryTapDetector({
    super.key,
    required this.onTap,
    required this.child,
  });

  @override
  State<GalleryTapDetector> createState() => _GalleryTapDetectorState();
}

class _GalleryTapDetectorState extends State<GalleryTapDetector> {
  /// The pointers down now, with where each went down.
  final _down = <int, Offset>{};

  /// Whether the current touch can still be a tap.
  bool _candidate = false;

  /// Ends the current touch's chance of being a tap once it is held as long
  /// as a long press. A timer rather than event time stamps, which test
  /// gestures do not fill in.
  Timer? _held;

  /// A tap waiting out the double-tap time, and where it landed.
  Timer? _pending;
  Offset? _pendingAt;

  /// Whether the current touch is the second half of a double tap.
  bool _second = false;

  @override
  void dispose() {
    _pending?.cancel();
    _held?.cancel();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    _down[event.pointer] = event.position;
    if (_down.length > 1) {
      // A second finger: a pinch, not a tap.
      _candidate = false;
      return;
    }

    _candidate = true;
    _held?.cancel();
    _held = Timer(kLongPressTimeout, () => _candidate = false);
    final waiting = _pendingAt;
    _second =
        _pending != null &&
        waiting != null &&
        (event.position - waiting).distance <= kDoubleTapSlop;
    if (_second) {
      _pending?.cancel();
      _pending = null;
    }
  }

  void _onMove(PointerMoveEvent event) {
    final start = _down[event.pointer];
    if (start != null && (event.position - start).distance > kTouchSlop) {
      _candidate = false;
    }
  }

  void _onUp(PointerUpEvent event) {
    _down.remove(event.pointer);
    final tap = _candidate && !_second && _down.isEmpty;
    _candidate = false;
    _held?.cancel();
    if (!tap) return;

    final at = event.position;
    _pendingAt = at;
    _pending = Timer(kDoubleTapTimeout, () {
      _pending = null;
      _pendingAt = null;
      if (mounted) widget.onTap(at);
    });
  }

  void _onCancel(PointerCancelEvent event) {
    _down.remove(event.pointer);
    _candidate = false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: _onUp,
    onPointerCancel: _onCancel,
    child: widget.child,
  );
}
