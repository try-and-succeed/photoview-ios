import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/widgets/face_grid.dart';

import 'support/localized_app.dart';

FaceGroup _group({String? label, required int count}) =>
    FaceGroup(id: '1', label: label, imageFaceCount: count);

Future<void> _pumpGrid(
  WidgetTester tester,
  List<FaceGroup> groups, {
  Locale? locale,
}) async {
  // The tile draws a thumbnail, which reads the session for its cookie.
  await tester.pumpWidget(
    ProviderScope(
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: CustomScrollView(
            slivers: [FaceSliverGrid(faceGroups: groups)],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('unlabeledFaceLabel', () {
    test('says how many pictures someone unnamed is in', () {
      expect(unlabeledFaceLabel('Unlabeled', 12), 'Unlabeled · 12');
    });

    test('leaves out a count the server did not give', () {
      // Zero is what an uncounted group looks like, and "· 0" would read as a
      // person in no pictures at all.
      expect(unlabeledFaceLabel('Unlabeled', 0), 'Unlabeled');
      expect(unlabeledFaceLabel('Unlabeled', -1), 'Unlabeled');
    });

    test('groups the digits the way the app language does', () {
      Intl.defaultLocale = 'de';
      addTearDown(() => Intl.defaultLocale = null);

      expect(unlabeledFaceLabel('Nicht zugeordnet', 1234), 'Nicht zugeordnet · 1.234');
    });
  });

  testWidgets('an unnamed face shows its count', (tester) async {
    await _pumpGrid(tester, [_group(count: 7)]);

    expect(find.text('Unlabeled · 7'), findsOneWidget);
  });

  testWidgets('a named face is left as it was', (tester) async {
    // The name tells people apart already; the request was for the count
    // where it is missing.
    await _pumpGrid(tester, [_group(label: 'Regina', count: 7)]);

    expect(find.text('Regina'), findsOneWidget);
    expect(find.textContaining('· 7'), findsNothing);
  });

  testWidgets('two unnamed faces are told apart by their counts', (
    tester,
  ) async {
    await _pumpGrid(tester, [
      _group(count: 40),
      _group(count: 2),
    ]);

    expect(find.text('Unlabeled · 40'), findsOneWidget);
    expect(find.text('Unlabeled · 2'), findsOneWidget);
  });
}
