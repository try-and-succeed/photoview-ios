import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/state/people_order.dart';
import 'package:photoview/state/search_limit.dart' show settingsStoreProvider;

FaceGroup _group(String id, {String? label, int count = 1}) =>
    FaceGroup(id: id, label: label, imageFaceCount: count);

class _MemorySettings extends SettingsStore {
  String? order;

  @override
  Future<String?> peopleOrder() async => order;

  @override
  Future<void> setPeopleOrder(String? value) async => order = value;
}

void main() {
  group('orderedFaceGroups', () {
    test('named people come first, then the unnamed', () {
      final ordered = orderedFaceGroups([
        _group('1', count: 9),
        _group('2', label: 'Bea', count: 1),
        _group('3', count: 4),
      ], PeopleOrder.alphabetical);

      expect(ordered.map((g) => g.id), ['2', '1', '3']);
    });

    test('names are ordered by name, not by how often they appear', () {
      // The point of the setting: one person is often split into several
      // groups, and the big one is not necessarily the one being looked for.
      final ordered = orderedFaceGroups([
        _group('1', label: 'Zoe', count: 400),
        _group('2', label: 'Anna', count: 2),
        _group('3', label: 'Mia', count: 50),
      ], PeopleOrder.alphabetical);

      expect(ordered.map((g) => g.label), ['Anna', 'Mia', 'Zoe']);
    });

    test('by count keeps the server order for the named', () {
      final ordered = orderedFaceGroups([
        _group('2', label: 'Anna', count: 2),
        _group('1', label: 'Zoe', count: 400),
      ], PeopleOrder.byCount);

      expect(ordered.map((g) => g.label), ['Zoe', 'Anna']);
    });

    test('the unnamed stay ordered by count under either setting', () {
      for (final order in PeopleOrder.values) {
        final ordered = orderedFaceGroups([
          _group('1', count: 3),
          _group('2', count: 30),
        ], order);

        expect(ordered.map((g) => g.id), ['2', '1'], reason: order.name);
      }
    });

    test('umlauts sort where a reader expects them', () {
      // Dart compares code units, which puts "Ö" after "Z".
      final ordered = orderedFaceGroups([
        _group('1', label: 'Zimmermann'),
        _group('2', label: 'Öztürk'),
        _group('3', label: 'Ärztin'),
      ], PeopleOrder.alphabetical);

      expect(ordered.map((g) => g.label), ['Ärztin', 'Öztürk', 'Zimmermann']);
    });

    test('a name of spaces is no name', () {
      final ordered = orderedFaceGroups([
        _group('1', label: '   ', count: 1),
        _group('2', count: 8),
      ], PeopleOrder.alphabetical);

      expect(
        ordered.map((g) => g.id),
        ['2', '1'],
        reason: 'both unnamed, so by count',
      );
    });

    test('equal keys fall back to the id, so paging cannot drop a person', () {
      // Without a final key the database may return equal rows in a different
      // order on the next page request, and someone shows up twice or not at
      // all. The same bug was once fixed in the server's search.
      final ordered = orderedFaceGroups([
        _group('9', label: 'Anna', count: 1),
        _group('3', label: 'Anna', count: 1),
        _group('7', count: 5),
        _group('2', count: 5),
      ], PeopleOrder.alphabetical);

      expect(ordered.map((g) => g.id), ['3', '9', '2', '7']);
    });

    test('nothing in, nothing out', () {
      expect(orderedFaceGroups(const [], PeopleOrder.alphabetical), isEmpty);
    });
  });

  group('sortableName', () {
    test('folds case and the diacritics of the app\'s languages', () {
      expect(sortableName('Öztürk'), 'ozturk');
      expect(sortableName('  Ærø '), 'aerø'.replaceAll('ø', 'o'));
      expect(sortableName('Straße'), 'strasse');
      expect(sortableName('Łukasz'), 'lukasz');
    });

    test('leaves scripts it knows nothing about alone', () {
      expect(sortableName('Анна'), 'анна');
    });
  });

  group('the chosen order', () {
    test('defaults to alphabetical and outlives the session', () async {
      final settings = _MemorySettings();

      final first = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(settings)],
      );
      addTearDown(first.dispose);

      expect(
        await first.read(peopleOrderProvider.future),
        PeopleOrder.alphabetical,
      );

      await first.read(peopleOrderProvider.notifier).choose(PeopleOrder.byCount);
      expect(settings.order, 'byCount');

      final afterRestart = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(settings)],
      );
      addTearDown(afterRestart.dispose);

      expect(
        await afterRestart.read(peopleOrderProvider.future),
        PeopleOrder.byCount,
      );
    });

    test('a stored value we no longer know falls back to the default', () async {
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(
            _MemorySettings()..order = 'by-phase-of-the-moon',
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(peopleOrderProvider.future),
        PeopleOrder.alphabetical,
      );
    });
  });
}
