import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/screens/app_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The test font draws every glyph as a square as wide as the font size, so
  // widths are simple: a 12 px label is 12 px per character.
  const style = TextStyle(fontSize: 12, letterSpacing: 0.5);

  group('fittingLabelStyle', () {
    test('keeps the size when every label fits', () {
      final fitted = fittingLabelStyle(
        style,
        ['Fotos', 'Alben'],
        tabWidth: 82,
        textScaler: TextScaler.noScaling,
      );

      expect(fitted.fontSize, 12);
      expect(fitted.letterSpacing, 0, reason: 'spacing is dropped regardless');
    });

    test('shrinks all labels until the longest fits', () {
      // 6 characters × 12 = 72 px in a 64 px space: scaled by 64 / 72.
      final fitted = fittingLabelStyle(
        style,
        ['Fotos', 'Photos'],
        tabWidth: 72,
        textScaler: TextScaler.noScaling,
      );

      expect(fitted.fontSize, closeTo(12 * 64 / 72, 0.01));
    });

    test('counts the system font scale', () {
      final fitted = fittingLabelStyle(
        style,
        ['Fotos'],
        tabWidth: 82,
        textScaler: const TextScaler.linear(1.3),
      );

      // 5 × 12 × 1.3 = 78 px does not fit into 74 px.
      expect(fitted.fontSize, lessThan(12));
    });

    test('does not shrink past the readable minimum', () {
      final fitted = fittingLabelStyle(
        style,
        ['Einstellungen'],
        tabWidth: 82,
        textScaler: TextScaler.noScaling,
      );

      expect(fitted.fontSize, 12 * minimumLabelScale);
    });
  });
}
