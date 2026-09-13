import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/widgets/face_grid.dart';

FaceGroup _face(Thumbnail? thumbnail) => FaceGroup(
  id: '1',
  label: 'Someone',
  imageFaceCount: 1,
  rectangle: const FaceRectangle(minX: 0.2, maxX: 0.5, minY: 0.2, maxY: 0.5),
  thumbnail: thumbnail,
);

Future<void> _pump(WidgetTester tester, FaceGroup face) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(home: Scaffold(body: FaceThumbnail(face: face))),
  ),
);

/// Every transform in the tile must be usable.
///
/// An infinite or NaN entry does not throw — Flutter simply fails to paint —
/// so the matrix has to be inspected for the tile to be provably rendered.
void _expectFiniteTransforms(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.byType(Transform));
  expect(transforms, isNotEmpty, reason: 'the tile scales and offsets');

  for (final transform in transforms) {
    for (final value in transform.transform.storage) {
      expect(
        value.isFinite,
        isTrue,
        reason: 'matrix entry $value makes the tile unpaintable',
      );
    }
  }
}

void main() {
  group('FaceThumbnail', () {
    testWidgets('renders a normal thumbnail', (tester) async {
      await _pump(
        tester,
        _face(const Thumbnail(url: 'photo/a.jpg', width: 800, height: 600)),
      );

      expect(tester.takeException(), isNull);
      _expectFiniteTransforms(tester);
    });

    testWidgets('survives a thumbnail of zero width', (tester) async {
      // Missing dimensions are stored as 0. A zero width made the aspect ratio
      // 0, the vertical scale infinite, and the transform matrix invalid.
      await _pump(
        tester,
        _face(const Thumbnail(url: 'photo/a.jpg', width: 0, height: 600)),
      );

      expect(tester.takeException(), isNull);
      _expectFiniteTransforms(tester);
    });

    testWidgets('survives a thumbnail of zero height', (tester) async {
      await _pump(
        tester,
        _face(const Thumbnail(url: 'photo/a.jpg', width: 800, height: 0)),
      );

      expect(tester.takeException(), isNull);
      _expectFiniteTransforms(tester);
    });

    testWidgets('survives a missing thumbnail', (tester) async {
      await _pump(tester, _face(null));

      expect(tester.takeException(), isNull);
      _expectFiniteTransforms(tester);
    });
  });
}
