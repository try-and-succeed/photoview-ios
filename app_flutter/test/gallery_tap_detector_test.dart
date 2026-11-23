import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/widgets/gallery_tap_detector.dart';

void main() {
  late List<Offset> taps;

  Future<void> pump(WidgetTester tester, {Widget? inside}) async {
    taps = [];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GalleryTapDetector(
          onTap: taps.add,
          child: inside ?? const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Lets the double-tap time run out, after which a tap is reported.
  Future<void> waitOut(WidgetTester tester) =>
      tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));

  const at = Offset(200, 300);

  testWidgets('a tap whose finger shakes a little is still a tap', (
    tester,
  ) async {
    // What a fingertip does; the photo view took this for panning on a
    // zoomed photo and dropped the tap.
    await pump(tester);
    final finger = await tester.startGesture(at);
    await finger.moveBy(const Offset(2, -1));
    await finger.moveBy(const Offset(1, 2));
    await finger.up();
    expect(taps, isEmpty, reason: 'not before the double-tap time');

    await waitOut(tester);
    expect(taps, [at + const Offset(3, 1)]);
  });

  testWidgets('is reported even when a gesture recognizer below wins', (
    tester,
  ) async {
    // A pan recognizer under it that, like the photo view's when zoomed,
    // takes the gesture on the first move.
    await pump(
      tester,
      inside: GestureDetector(
        onPanUpdate: (_) {},
        dragStartBehavior: DragStartBehavior.down,
        child: const SizedBox.expand(),
      ),
    );
    final finger = await tester.startGesture(at);
    await finger.moveBy(const Offset(4, 0));
    await finger.up();
    await waitOut(tester);

    expect(taps, hasLength(1));
  });

  testWidgets('a double tap is no tap', (tester) async {
    await pump(tester);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(at + const Offset(5, 5));
    await waitOut(tester);

    expect(taps, isEmpty);
  });

  testWidgets('two taps far apart are two taps', (tester) async {
    await pump(tester);
    await tester.tapAt(at);
    await waitOut(tester);
    await tester.tapAt(const Offset(20, 20));
    await waitOut(tester);

    expect(taps, [at, const Offset(20, 20)]);
  });

  testWidgets('a swipe is no tap', (tester) async {
    await pump(tester);
    await tester.dragFrom(at, const Offset(-120, 0));
    await waitOut(tester);

    expect(taps, isEmpty);
  });

  testWidgets('a pinch is no tap', (tester) async {
    await pump(tester);
    final one = await tester.startGesture(at);
    final two = await tester.startGesture(at + const Offset(60, 0));
    await two.up();
    await one.up();
    await waitOut(tester);

    expect(taps, isEmpty);
  });

  testWidgets('a long press is no tap', (tester) async {
    await pump(tester);
    final finger = await tester.startGesture(at);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await finger.up();
    await waitOut(tester);

    expect(taps, isEmpty);
  });
}
