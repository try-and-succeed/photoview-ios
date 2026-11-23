import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/people_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
import 'package:photoview/state/library.dart';
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

/// Two named people, one confirmed throughout, and one unnamed — whose status
/// only comes when the list asks for it, as from the server.
class _PeopleClient extends PhotoviewClient {
  _PeopleClient({this.allNamedVerified = false}) : super(_session);

  final bool allNamedVerified;

  /// What `withStatus` each page was fetched with.
  final fetches = <bool>[];
  final verifies = <List<String>>[];

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
    bool withStatus = false,
  }) async {
    fetches.add(withStatus);
    if (offset > 0) return const [];
    bool? status(bool verified) => withStatus ? verified : null;
    return [
      FaceGroup(
        id: '1',
        label: 'Anna',
        imageFaceCount: 5,
        allVerified: status(true),
      ),
      FaceGroup(
        id: '2',
        label: 'Ben',
        imageFaceCount: 4,
        allVerified: status(allNamedVerified),
      ),
      FaceGroup(id: '3', imageFaceCount: 3, allVerified: status(false)),
    ];
  }

  @override
  Future<int> setImageFacesVerified(
    List<String> imageFaceIds, {
    required bool verified,
  }) async {
    verifies.add(imageFaceIds);
    return imageFaceIds.length;
  }
}

Override _capability(bool supported) => serverCapabilitiesProvider.overrideWith(
  (ref) async => ServerCapabilities({
    Capability.faceVerification: supported
        ? CapabilityState.supported
        : CapabilityState.unsupported,
  }),
);

void main() {
  late _PeopleClient client;

  Future<ProviderContainer> open(
    WidgetTester tester, {
    bool supported = true,
    bool allNamedVerified = false,
  }) async {
    client = _PeopleClient(allNamedVerified: allNamedVerified);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
          _capability(supported),
        ],
        child: localizedApp(home: const PeopleScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(PeopleScreen)));
  }

  List<String?> shown(WidgetTester tester) => tester
      .widget<FaceSliverGrid>(find.byType(FaceSliverGrid))
      .faceGroups
      .map((g) => g.label)
      .toList();

  group('FaceGroup.fromJson', () {
    Map<String, dynamic> json({List<dynamic>? unverified, bool faces = true}) =>
        {
          'id': '7',
          'label': 'Anna',
          'imageFaceCount': 2,
          'imageFaces': faces
              ? [
                  {'id': '70'},
                ]
              : [],
          'unverifiedFaces': ?unverified,
        };

    test('no unconfirmed face means confirmed throughout', () {
      expect(FaceGroup.fromJson(json(unverified: [])).allVerified, isTrue);
    });

    test('one unconfirmed face is enough to say no', () {
      final group = FaceGroup.fromJson(
        json(
          unverified: [
            {'id': '71'},
          ],
        ),
      );
      expect(group.allVerified, isFalse);
    });

    test('a person without faces is not confirmed', () {
      expect(
        FaceGroup.fromJson(json(unverified: [], faces: false)).allVerified,
        isFalse,
      );
    });

    test('not asked, not known', () {
      expect(FaceGroup.fromJson(json()).allVerified, isNull);
    });
  });

  testWidgets('a person confirmed throughout carries the green tick', (
    tester,
  ) async {
    await open(tester);

    expect(client.fetches.last, isTrue);
    expect(find.byType(VerifiedPersonBadge), findsOneWidget);
    // Merged into the tile's own node, with the name, for a screen reader.
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'All faces confirmed',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the filter keeps the named people without the tick', (
    tester,
  ) async {
    await open(tester);
    expect(shown(tester), hasLength(3));

    await tester.tap(find.byTooltip('Only people with unconfirmed faces'));
    await tester.pumpAndSettle();
    expect(shown(tester), ['Ben']);

    await tester.tap(find.byTooltip('Show everybody'));
    await tester.pumpAndSettle();
    expect(shown(tester), hasLength(3));
  });

  testWidgets('with everybody confirmed, the filter says so', (tester) async {
    await open(tester, allNamedVerified: true);

    await tester.tap(find.byTooltip('Only people with unconfirmed faces'));
    await tester.pumpAndSettle();

    expect(
      find.text('Every named person has all their faces confirmed.'),
      findsOneWidget,
    );
    expect(find.byType(FaceSliverGrid), findsNothing);
  });

  testWidgets('a server without confirming gets neither tick nor filter', (
    tester,
  ) async {
    await open(tester, supported: false);

    expect(client.fetches, everyElement(isFalse));
    expect(find.byType(VerifiedPersonBadge), findsNothing);
    expect(find.byTooltip('Only people with unconfirmed faces'), findsNothing);
  });

  testWidgets('confirming faces fetches the people again', (tester) async {
    final container = await open(tester);
    final before = client.fetches.length;

    await container.read(faceActionsProvider).verifyFaces([
      '70',
    ], verified: true);
    await tester.pumpAndSettle();

    expect(client.verifies, [
      ['70'],
    ]);
    expect(client.fetches.length, greaterThan(before));
  });
}
