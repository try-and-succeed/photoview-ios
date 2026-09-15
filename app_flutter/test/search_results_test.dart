import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/widgets/search_results.dart';

void main() {
  group('planSearchSection', () {
    test('a handful of results keeps the thumbnail grid', () {
      for (final count in [1, 12, compactSearchThreshold]) {
        final plan = planSearchSection(count);

        expect(plan.layout, SearchResultLayout.grid, reason: '$count');
        expect(plan.shown, count);
        expect(plan.hasHidden, isFalse);
      }
    });

    test('one past the threshold switches to compact rows', () {
      final plan = planSearchSection(compactSearchThreshold + 1);

      expect(plan.layout, SearchResultLayout.compact);
      expect(plan.shown, compactSearchThreshold + 1);
      expect(plan.hasHidden, isFalse);
    });

    test('the ceiling caps what is built and reports the rest', () {
      final plan = planSearchSection(maxRenderedSearchResults + 250);

      expect(plan.shown, maxRenderedSearchResults);
      expect(plan.hidden, 250);
      expect(plan.hasHidden, isTrue);
      expect(plan.layout, SearchResultLayout.compact);
    });

    test('exactly at the ceiling nothing is hidden', () {
      final plan = planSearchSection(maxRenderedSearchResults);

      expect(plan.shown, maxRenderedSearchResults);
      expect(plan.hasHidden, isFalse);
    });

    test('shown and hidden always add up to the total', () {
      // The note tells the user how many are missing, so the arithmetic has to
      // hold for every size — a wrong count reads as lost files.
      for (final count in [0, 1, 50, 51, 499, 500, 501, 5000, 100000]) {
        final plan = planSearchSection(count);

        expect(plan.shown + plan.hidden, count, reason: '$count');
        expect(plan.shown, lessThanOrEqualTo(maxRenderedSearchResults));
        expect(plan.hidden, greaterThanOrEqualTo(0));
      }
    });

    test('no results renders nothing rather than an empty grid', () {
      final plan = planSearchSection(0);

      expect(plan.shown, 0);
      expect(plan.hasHidden, isFalse);
    });

    test('a nonsense count is treated as none', () {
      final plan = planSearchSection(-3);

      expect(plan.shown, 0);
      expect(plan.hidden, 0);
    });

    test('the compact threshold is below the ceiling', () {
      // Otherwise a capped section would still try to build a grid of 500
      // thumbnails, which is the case the ceiling exists to prevent.
      expect(compactSearchThreshold, lessThan(maxRenderedSearchResults));
    });
  });
}
