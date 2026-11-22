import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/people_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/widgets/face_grid.dart';

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

/// Three named people first, as the server sends them, then 200 unnamed.
class _PeopleClient extends PhotoviewClient {
  _PeopleClient() : super(_session);

  static const _names = ['Meike Ortloff', 'Henrik Hoppe', 'Anna Hoppe'];
  final offsets = <int>[];

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
    bool withStatus = false,
  }) async {
    offsets.add(offset);
    return [
      for (var i = offset; i < offset + limit && i < 203; i++)
        FaceGroup(
          id: '$i',
          label: i < _names.length ? _names[i] : null,
          imageFaceCount: 300 - i,
        ),
    ];
  }
}

void main() {
  late _PeopleClient client;

  Future<void> open(WidgetTester tester) async {
    client = _PeopleClient();
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

  int shownPeople(WidgetTester tester) => tester
      .widget<FaceSliverGrid>(find.byType(FaceSliverGrid))
      .faceGroups
      .length;

  testWidgets('a typed name keeps only the people it is part of', (
    tester,
  ) async {
    await open(tester);
    expect(shownPeople(tester), greaterThan(3));

    await tester.tap(find.byTooltip('Find by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hOPPE ');
    await tester.pumpAndSettle();

    final shown = tester
        .widget<FaceSliverGrid>(find.byType(FaceSliverGrid))
        .faceGroups
        .map((g) => g.label)
        .toList();
    expect(shown, unorderedEquals(['Henrik Hoppe', 'Anna Hoppe']));
  });

  testWidgets('while filtering, scrolling fetches no unnamed people', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Find by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Meike');
    await tester.pumpAndSettle();

    final before = client.offsets.length;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();

    expect(client.offsets.length, before);
  });

  testWidgets('a name nobody has says so, and closing shows everybody', (
    tester,
  ) async {
    await open(tester);
    final all = shownPeople(tester);

    await tester.tap(find.byTooltip('Find by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Zacharias');
    await tester.pumpAndSettle();

    expect(find.text('Nobody by that name'), findsOneWidget);
    expect(find.byType(FaceSliverGrid), findsNothing);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    // At least everybody from before: the grid growing back may bring the end
    // close enough for the next page, as any scrolling would.
    expect(shownPeople(tester), greaterThanOrEqualTo(all));
  });

  testWidgets('back closes the name field before leaving', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Find by name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Meike');
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(shownPeople(tester), greaterThan(3));
  });
}
