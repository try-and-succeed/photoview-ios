import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// intl exports a TextDirection of its own, which would shadow the one the
// text painter below needs.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:photoview/api/models.dart';
import 'package:photoview/widgets/face_grid.dart';

import 'support/localized_app.dart';

FaceGroup _group({String? label, required int count}) =>
    FaceGroup(id: '1', label: label, imageFaceCount: count);

Future<void> _pumpGrid(
  WidgetTester tester,
  List<FaceGroup> groups, {
  Locale? locale,

  /// The narrow side of a phone held upright, where the tiles are smallest.
  double width = 360,
}) async {
  // The tile draws a thumbnail, which reads the session for its cookie.
  await tester.pumpWidget(
    ProviderScope(
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: FaceSliverGrid(faceGroups: groups),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// What of [finder]'s text actually fits in the tile.
///
/// A `Text` that does not fit is painted with an ellipsis while the widget
/// keeps its whole string, so asking the widget proves nothing. The laid-out
/// paragraph is what knows where the cut falls.
String _visibleText(WidgetTester tester, Finder finder) {
  final rich = tester.widget<RichText>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  );
  final box = tester.renderObject<RenderBox>(finder);

  final painter = TextPainter(
    text: rich.text,
    textDirection: TextDirection.ltr,
    maxLines: rich.maxLines,
    ellipsis: '…',
  )..layout(maxWidth: box.size.width);

  final end = painter.getPositionForOffset(
    Offset(painter.width, painter.height / 2),
  );
  return rich.text.toPlainText().substring(0, end.offset);
}

void main() {
  group('unlabeledFaceLabel', () {
    test('puts the number first, where it cannot be cut off', () {
      expect(unlabeledFaceLabel('Unlabeled', 12), '12 · Unlabeled');
    });

    test('leaves out a count the server did not give', () {
      expect(unlabeledFaceLabel('Unlabeled', 0), 'Unlabeled');
      expect(unlabeledFaceLabel('Unlabeled', -1), 'Unlabeled');
    });

    test('groups the digits the way the app language does', () {
      Intl.defaultLocale = 'de';
      addTearDown(() => Intl.defaultLocale = null);

      expect(unlabeledFaceLabel('Nicht zugeordnet', 1234), '1.234 · Nicht zugeordnet');
    });
  });

  testWidgets('an unnamed face shows its count', (tester) async {
    await _pumpGrid(tester, [_group(count: 7)]);

    expect(find.textContaining('Unlabeled'), findsOneWidget);
    expect(find.text('7 · Unlabeled'), findsOneWidget);
  });

  testWidgets('the number survives a tile too narrow for the word', (
    tester,
  ) async {
    // The reported bug: with the word first, a tile on a phone held upright
    // cut off the number — the only thing telling two unnamed people apart.
    await _pumpGrid(
      tester,
      [_group(count: 1234)],
      locale: const Locale('de'),
      width: 320,
    );

    // Found by the word rather than the whole line, so this asks where the
    // cut falls and not how the line happens to be worded.
    final label = find.textContaining('Nicht zugeordnet');
    expect(label, findsOneWidget);

    final visible = _visibleText(tester, label);
    expect(
      visible,
      contains('1.234'),
      reason: 'the count is what has to survive the cut, whole',
    );
  });

  testWidgets('a tile fits its own contents on a narrow phone', (tester) async {
    // Three columns on a 320dp screen used to leave the tile shorter than the
    // thumbnail and its line together, which Flutter reports as an overflow.
    await _pumpGrid(tester, [_group(count: 12)], width: 320);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a count of zero is left out entirely', (tester) async {
    await _pumpGrid(tester, [_group(count: 0)]);

    expect(find.text('Unlabeled'), findsOneWidget);
  });

  testWidgets('a named face is left as it was', (tester) async {
    // The name tells people apart already; the request was for the count
    // where it is missing.
    await _pumpGrid(tester, [_group(label: 'Regina', count: 7)]);

    expect(find.text('Regina'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('two unnamed faces are told apart by their counts', (
    tester,
  ) async {
    await _pumpGrid(tester, [_group(count: 40), _group(count: 2)]);

    expect(find.text('40 · Unlabeled'), findsOneWidget);
    expect(find.text('2 · Unlabeled'), findsOneWidget);
  });
}
