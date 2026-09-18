import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'search_limit.dart' show settingsStoreProvider;

/// How the people who have a name are ordered.
///
/// The unnamed are always ordered by how many photos they appear in: they have
/// nothing else to be ordered by, and the biggest heaps are the ones worth
/// naming first.
enum PeopleOrder {
  /// By name. The default: face detection splits one person into several
  /// groups often enough that ordering by count scatters the same person over
  /// the whole list, and the person with the most photos is rarely the one
  /// being looked for.
  alphabetical,

  /// Most photos first, which is what the server sends.
  byCount;

  static PeopleOrder? byName(String? name) {
    for (final order in values) {
      if (order.name == name) return order;
    }
    return null;
  }
}

/// Lowercased, with the diacritics that would otherwise sort a name to the end.
///
/// Dart compares strings by code unit, which puts "Öztürk" after "Zimmermann"
/// and "Ärztin" after "Zoe" — wrong in every language that has the letters.
/// This is not full collation, but it covers Latin diacritics, which is what
/// names in this app's languages are made of.
String sortableName(String name) {
  const folded = {
    'ä': 'a', 'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'æ': 'ae',
    'ç': 'c', 'ć': 'c', 'č': 'c',
    'ď': 'd', 'đ': 'd',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e', 'ě': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
    'ö': 'o', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
    'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ß': 'ss',
    'ť': 't', 'ţ': 't',
    'ü': 'u', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ū': 'u', 'ů': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ž': 'z', 'ź': 'z', 'ż': 'z',
  };

  final buffer = StringBuffer();
  for (final character in name.toLowerCase().trim().split('')) {
    buffer.write(folded[character] ?? character);
  }
  return buffer.toString();
}

/// Whether this face group has been given a name.
///
/// A label of spaces counts as none: the server stores what it is sent, and a
/// person called " " would sort among the named and show an empty title.
bool faceGroupIsNamed(FaceGroup group) =>
    (group.label ?? '').trim().isNotEmpty;

/// The people, in the order they are shown.
///
/// Named people first, then the unnamed. Ordering happens here rather than
/// being asked of the server, which sorts by name-or-not and then by count and
/// offers nothing else.
///
/// Every comparison ends at the id, so that two people with the same name, or
/// the same number of photos, keep a fixed order. Without that last step the
/// database is free to return equal rows in a different order on the next page
/// request, and a person shows up twice or not at all.
List<FaceGroup> orderedFaceGroups(List<FaceGroup> groups, PeopleOrder order) {
  final named = [for (final g in groups) if (faceGroupIsNamed(g)) g];
  final unnamed = [for (final g in groups) if (!faceGroupIsNamed(g)) g];

  int byCount(FaceGroup a, FaceGroup b) {
    final count = b.imageFaceCount.compareTo(a.imageFaceCount);
    return count != 0 ? count : a.id.compareTo(b.id);
  }

  named.sort(
    order == PeopleOrder.alphabetical
        ? (a, b) {
            final name = sortableName(
              a.label!,
            ).compareTo(sortableName(b.label!));
            return name != 0 ? name : a.id.compareTo(b.id);
          }
        : byCount,
  );
  unnamed.sort(byCount);

  return [...named, ...unnamed];
}

/// The chosen order, kept on the device like the other display preferences.
class PeopleOrderNotifier extends AsyncNotifier<PeopleOrder> {
  @override
  Future<PeopleOrder> build() async =>
      PeopleOrder.byName(await ref.read(settingsStoreProvider).peopleOrder()) ??
      PeopleOrder.alphabetical;

  Future<void> choose(PeopleOrder order) async {
    state = AsyncData(order);
    await ref.read(settingsStoreProvider).setPeopleOrder(order.name);
  }
}

final peopleOrderProvider =
    AsyncNotifierProvider<PeopleOrderNotifier, PeopleOrder>(
      PeopleOrderNotifier.new,
    );
