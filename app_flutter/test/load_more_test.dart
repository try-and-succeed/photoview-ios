import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/widgets/load_more.dart';

/// A list long enough that its end starts far outside the viewport.
Widget _list({
  required int items,
  required VoidCallback onLoadMore,
  bool hasMore = true,
  ScrollController? controller,
}) => MaterialApp(
  home: Scaffold(
    body: LoadMoreOnScroll(
      hasMore: hasMore,
      onLoadMore: onLoadMore,
      child: ListView.builder(
        controller: controller,
        itemCount: items,
        itemBuilder: (context, index) =>
            SizedBox(height: 100, child: Text('item $index')),
      ),
    ),
  ),
);

void main() {
  group('LoadMoreOnScroll', () {
    testWidgets('does not ask for more while the end is far away', (
      tester,
    ) async {
      // The regression this exists for: the old trigger fired from the item
      // builder, so a list whose end was nowhere near the screen still asked
      // for page after page until the whole library was loaded.
      var calls = 0;

      await tester.pumpWidget(_list(items: 500, onLoadMore: () => calls++));
      await tester.pumpAndSettle();

      expect(calls, 0);
    });

    testWidgets('asks once the end comes within reach', (tester) async {
      var calls = 0;
      final controller = ScrollController();

      await tester.pumpWidget(
        _list(items: 500, onLoadMore: () => calls++, controller: controller),
      );
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'precondition');

      controller.jumpTo(controller.position.maxScrollExtent - 200);
      await tester.pump();

      expect(calls, greaterThan(0));
    });

    testWidgets('asks when the content does not fill the screen', (
      tester,
    ) async {
      // Nothing to scroll means no scroll notification, so the first short
      // page would otherwise never be followed by a second.
      var calls = 0;

      await tester.pumpWidget(_list(items: 2, onLoadMore: () => calls++));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(0));
    });

    testWidgets('stays quiet once everything is loaded', (tester) async {
      var calls = 0;
      final controller = ScrollController();

      await tester.pumpWidget(
        _list(
          items: 500,
          hasMore: false,
          onLoadMore: () => calls++,
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      expect(calls, 0);
    });
  });
}
