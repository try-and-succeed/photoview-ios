import 'package:flutter/material.dart';

/// A [CustomScrollView] with a scrollbar that can be dragged.
///
/// Exists because getting from one end of a library to the other by swiping is
/// no way to spend an afternoon. Material's scrollbar is not draggable on
/// phones by default — it is drawn, but only as an indicator — so this passes
/// `interactive` and gives both halves the same controller, which a scrollbar
/// needs in order to know what it is scrolling.
///
/// What it cannot do is reach past what has been loaded. The timeline, albums
/// and people arrive a page at a time, so dragging to the bottom lands at the
/// end of the pages fetched so far and the next one is asked for there. On a
/// library the size of the benchmark server that is still a long way from the
/// oldest photo.
class ScrollableView extends StatefulWidget {
  final List<Widget> slivers;
  final ScrollPhysics? physics;

  const ScrollableView({super.key, required this.slivers, this.physics});

  @override
  State<ScrollableView> createState() => _ScrollableViewState();
}

class _ScrollableViewState extends State<ScrollableView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      interactive: true,
      // Kept on screen. By default the thumb fades about half a second after
      // scrolling stops, so reaching for it means scrolling first and then
      // grabbing a bar that is already going — measured on the S10, where the
      // drag did nothing at all unless it followed a swipe immediately.
      thumbVisibility: true,
      child: CustomScrollView(
        controller: _controller,
        physics: widget.physics,
        slivers: widget.slivers,
      ),
    );
  }
}
