import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/widgets/scrollable_view.dart';

Widget _host({int items = 200}) => MaterialApp(
  home: Scaffold(
    body: ScrollableView(
      slivers: [
        SliverList.builder(
          itemCount: items,
          itemBuilder: (context, index) =>
              SizedBox(height: 100, child: Text('item $index')),
        ),
      ],
    ),
  ),
);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

void main() {
  testWidgets('the scrollbar can be dragged to the far end', (tester) async {
    // The point of it: reaching the other end of a library by swiping is no
    // way to spend an afternoon.
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(_position(tester).pixels, 0);

    // A short scroll first, because the thumb is only drawn once the view has
    // moved — which is also how a user finds it.
    await tester.drag(find.text('item 1'), const Offset(0, -60));
    await tester.pumpAndSettle();
    final afterSwipe = _position(tester).pixels;

    final size = tester.getSize(find.byType(ScrollableView));
    // Near the top of the track: with two hundred items the thumb is short,
    // and starting below it would hit the track, which pages instead.
    await tester.dragFrom(Offset(size.width - 4, 8), const Offset(0, 200));
    await tester.pumpAndSettle();

    // The same 200 pixels of finger on the list itself move the list 200
    // pixels; on the thumb they cover a third of the whole thing.
    expect(
      _position(tester).pixels - afterSwipe,
      greaterThan(3000),
      reason: 'one drag of the thumb, not two hundred swipes',
    );
  });

  testWidgets('dragging the list itself still scrolls it', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.drag(find.text('item 1'), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(_position(tester).pixels, 300);
  });

  testWidgets('a list that fits on screen shows no thumb to grab', (
    tester,
  ) async {
    await tester.pumpWidget(_host(items: 2));
    await tester.pumpAndSettle();

    expect(_position(tester).maxScrollExtent, 0);
  });
}
