import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/people_screen.dart';
import 'package:photoview/screens/person_screen.dart';
import 'package:photoview/state/auth.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

class _FixedAuth extends AuthNotifier {
  @override
  Future<Session?> build() async => _session;
}

/// Answers as the server does: the destination keeps its own label, and the
/// sources are gone from the people list afterwards.
class _MergingClient extends PhotoviewClient {
  _MergingClient({required List<FaceGroup> people})
    : _people = [...people],
      super(_session);

  List<FaceGroup> _people;

  final merges = <(String, List<String>)>[];
  var recognizeCalls = 0;

  /// How many faces the server says it filed on the next `recognize`.
  int filed = 0;

  Object? failWith;

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
  }) async => _people.skip(offset).take(limit).toList();

  @override
  Future<String?> combineFaceGroups(
    String destinationFaceGroupId,
    List<String> sourceFaceGroupIds,
  ) async {
    merges.add((destinationFaceGroupId, sourceFaceGroupIds));
    final failure = failWith;
    if (failure != null) throw failure;

    _people = [
      for (final person in _people)
        if (!sourceFaceGroupIds.contains(person.id)) person,
    ];

    return _people
        .firstWhere((person) => person.id == destinationFaceGroupId)
        .label;
  }

  @override
  Future<int> recognizeUnlabeledFaces() async {
    recognizeCalls++;
    final failure = failWith;
    if (failure != null) throw failure;
    return filed;
  }

  @override
  Future<List<MediaItem>> personMedia(String faceGroupId) async => const [];
}

Future<void> _openPerson(
  WidgetTester tester,
  _MergingClient client, {
  required FaceGroup person,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
      child: localizedApp(home: PersonScreen(faceGroup: person)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPeople(WidgetTester tester, _MergingClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
      child: localizedApp(home: const PeopleScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const regina = FaceGroup(id: '7', label: 'Regina', imageFaceCount: 40);
  const stranger = FaceGroup(id: '8', imageFaceCount: 12);
  const other = FaceGroup(id: '9', label: 'Anna', imageFaceCount: 5);

  testWidgets('the picked person is folded into the one on screen', (
    tester,
  ) async {
    // Merging is what turns two tiles of the same person into one — and the
    // only way this server has of getting rid of a face group at all.
    final client = _MergingClient(people: const [regina, stranger, other]);
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(client.merges.single.$1, '7');
    expect(client.merges.single.$2, ['9']);
    expect(find.textContaining('Merged Anna'), findsOneWidget);
  });

  testWidgets('the person on screen is not offered as their own source', (
    tester,
  ) async {
    // A group merged into itself is a request the server can only refuse, and
    // offering it invites a tap that loses the user nothing but time.
    final client = _MergingClient(people: const [regina, stranger, other]);
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    // Once in the title of the screen behind the dialog, and nowhere in it.
    expect(find.text('Regina'), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
  });

  testWidgets('an unnamed person is listed with the count that tells them '
      'apart', (tester) async {
    // Everyone unnamed is called the same thing, so a list of them alone is
    // unusable without the number.
    final client = _MergingClient(people: const [regina, stranger]);
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    expect(find.text('12 · Unlabeled'), findsOneWidget);
  });

  testWidgets('the destination keeps its own name', (tester) async {
    // The server keeps the destination's label, so merging a named person
    // into an unnamed one leaves it unnamed — and the title has to say so,
    // rather than showing the name that was just absorbed.
    final client = _MergingClient(people: const [stranger, other]);
    await _openPerson(tester, client, person: stranger);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(client.merges.single.$1, '8');
    expect(client.merges.single.$2, ['9']);
    expect(
      find.widgetWithText(AppBar, 'Unlabeled'),
      findsOneWidget,
      reason: 'the destination had no name and still has none',
    );
  });

  testWidgets('backing out of the dialog merges nothing', (tester) async {
    final client = _MergingClient(people: const [regina, other]);
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(client.merges, isEmpty);
  });

  testWidgets('a merge the server refuses is reported, not swallowed', (
    tester,
  ) async {
    final client = _MergingClient(people: const [regina, other])
      ..failWith = const ApiException('Could not reach the server');
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not merge the people'), findsOneWidget);
  });

  testWidgets('a person with nobody to merge is told so', (tester) async {
    final client = _MergingClient(people: const [regina]);
    await _openPerson(tester, client, person: regina);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    expect(find.text('There is nobody else to merge'), findsOneWidget);
  });

  testWidgets('the people list reports how many faces the match filed', (
    tester,
  ) async {
    // The work happens on the server and changes people all over the list, so
    // the count is the only thing that says anything happened at all.
    final client = _MergingClient(people: const [regina, stranger])..filed = 12;
    await _openPeople(tester, client);

    await tester.tap(find.byIcon(Icons.person_search_outlined));
    await tester.pumpAndSettle();

    expect(client.recognizeCalls, 1);
    expect(find.text('Faces filed: 12'), findsOneWidget);
  });

  testWidgets('a match that fails is reported, not swallowed', (tester) async {
    final client = _MergingClient(people: const [regina, stranger])
      ..failWith = const ApiException('Could not reach the server');
    await _openPeople(tester, client);

    await tester.tap(find.byIcon(Icons.person_search_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('The match failed'), findsOneWidget);
  });
}
