import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/screens/merge_unlabeled_screen.dart';
import 'package:photoview/screens/people_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
import 'package:photoview/state/search_limit.dart' show settingsStoreProvider;
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

MergeFace _face(String id, String group) => MergeFace(
  id: id,
  groupId: group,
  rectangle: const FaceRectangle(minX: 0.1, maxX: 0.3, minY: 0.1, maxY: 0.3),
  mediaId: 'm$id',
);

/// Group 10 with two faces is the destination; 11 and 12 have one each.
final _three = MergeProposal(
  destinationId: '10',
  sourceGroupIds: const ['11', '12'],
  faces: [
    _face('1', '10'),
    _face('2', '10'),
    _face('3', '11'),
    _face('4', '12'),
  ],
);

/// Two groups of one face each.
final _two = MergeProposal(
  destinationId: '20',
  sourceGroupIds: const ['21'],
  faces: [_face('5', '20'), _face('6', '21')],
);

class _MergeClient extends PhotoviewClient {
  _MergeClient(this.proposals) : super(_session);

  List<MergeProposal> proposals;
  final dryRuns = <bool>[];
  final combines = <({String destination, List<String> sources})>[];
  var peopleFetches = 0;

  /// Fails the combine with this number, counted from 1.
  int? failCombine;

  /// Each request to flag faces for review: the face ids.
  final flagged = <List<String>>[];

  /// Fails the next request to flag faces for review.
  bool failFlag = false;

  @override
  Future<int> setImageFacesNeedsReview(
    List<String> imageFaceIds, {
    required bool needsReview,
  }) async {
    if (failFlag) {
      failFlag = false;
      throw const ApiException('offline');
    }
    expect(needsReview, isTrue);
    flagged.add(imageFaceIds);
    return imageFaceIds.length;
  }

  @override
  Future<List<MergeProposal>> mergeSimilarUnlabeledFaceGroups({
    required bool dryRun,
  }) async {
    dryRuns.add(dryRun);
    return proposals;
  }

  @override
  Future<String?> combineFaceGroups(
    String destinationFaceGroupId,
    List<String> sourceFaceGroupIds,
  ) async {
    if (combines.length + 1 == failCombine) {
      failCombine = null;
      throw const ApiException('offline');
    }
    combines.add((
      destination: destinationFaceGroupId,
      sources: sourceFaceGroupIds,
    ));
    return null;
  }

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
    bool withStatus = false,
  }) async {
    if (offset == 0) peopleFetches++;
    return offset == 0 ? const [_henrik] : const [];
  }

  final renames = <({String group, String? label})>[];

  /// Fails the next naming.
  bool failRename = false;

  @override
  Future<String?> setFaceGroupLabel(String faceGroupId, String? label) async {
    if (failRename) {
      failRename = false;
      throw const ApiException('offline');
    }
    renames.add((group: faceGroupId, label: label));
    return label;
  }
}

const _henrik = FaceGroup(id: '9', label: 'Henrik', imageFaceCount: 40);

CapabilityState _state(bool supported) =>
    supported ? CapabilityState.supported : CapabilityState.unsupported;

Override _capabilities({bool merge = true, bool flag = true}) =>
    serverCapabilitiesProvider.overrideWith(
      (ref) async => ServerCapabilities({
        Capability.mergeUnlabeledFaceGroups: _state(merge),
        Capability.faceNeedsReview: _state(flag),
        Capability.faceVerification: CapabilityState.supported,
      }),
    );

Future<void> _open(
  WidgetTester tester,
  _MergeClient client, {
  SettingsStore? settings,
  bool flag = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(settings ?? _MemorySettings()),
        _capabilities(flag: flag),
      ],
      child: localizedApp(home: const MergeUnlabeledScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// The turned-down proposals, kept in memory: the real store is tested on its
/// own above. Its write queue is static, and a queue left by a test outside
/// the widget zone is never run on inside one.
class _MemorySettings extends SettingsStore {
  final rejected = <String, Set<String>>{};

  @override
  Future<Set<String>> rejectedMergeProposals(String serverId) async => {
    ...?rejected[serverId],
  };

  @override
  Future<void> setRejectedMergeProposals(
    String serverId,
    Set<String> signatures,
  ) async => rejected[serverId] = {...signatures};
}

Finder _card(int index) => find.byType(Card).at(index);

Finder _inCard(int index, Finder finder) =>
    find.descendant(of: _card(index), matching: finder);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('MergeProposal', () {
    test('reads the server answer', () {
      final proposal = MergeProposal.fromJson({
        'destination': {'id': 10},
        'sourceFaceGroupIDs': [11, '12'],
        'imageFaces': [
          {
            'id': 1,
            'rectangle': {'minX': 0.1, 'maxX': 0.2, 'minY': 0.3, 'maxY': 0.4},
            'faceGroup': {'id': 11},
            'media': {
              'id': 7,
              'thumbnail': {'url': '/t.jpg', 'width': 400, 'height': 300},
            },
          },
        ],
      });

      expect(proposal.destinationId, '10');
      expect(proposal.sourceGroupIds, ['11', '12']);
      expect(proposal.groupIds, ['10', '11', '12']);
      final face = proposal.faces.single;
      expect(face.groupId, '11');
      expect(face.mediaId, '7');
      expect(face.thumbnail?.width, 400);
      expect(face.rectangle.maxY, 0.4);
    });

    test('the signature is the same however the groups are ordered', () {
      final again = MergeProposal(
        destinationId: '12',
        sourceGroupIds: const ['10', '11'],
        faces: const [],
      );
      expect(again.signature, _three.signature);
      expect(_two.signature, isNot(_three.signature));
    });

    test('merges the kept groups into the destination', () {
      final all = _three.mergeOf({'10', '11', '12'})!;
      expect(all.destination, '10');
      expect(all.sources, ['11', '12']);

      final without12 = _three.mergeOf({'10', '11'})!;
      expect(without12.sources, ['11']);
    });

    test(
      'without the destination, the kept group with the most faces is it',
      () {
        final proposal = MergeProposal(
          destinationId: '10',
          sourceGroupIds: const ['11', '12'],
          faces: [
            _face('1', '10'),
            _face('2', '11'),
            _face('3', '12'),
            _face('4', '12'),
          ],
        );
        final merge = proposal.mergeOf({'11', '12'})!;
        expect(merge.destination, '12');
        expect(merge.sources, ['11']);
      },
    );

    test('fewer than two groups is nothing to merge', () {
      expect(_three.mergeOf({'10'}), isNull);
      expect(_three.mergeOf({}), isNull);
    });
  });

  group('SettingsStore', () {
    test('keeps turned-down proposals per account', () async {
      final store = SettingsStore();
      await store.setSearchResultLimit('a', 50);
      await store.setRejectedMergeProposals('a', {'1,2', '3,4'});

      expect(await store.rejectedMergeProposals('a'), {'1,2', '3,4'});
      expect(await store.rejectedMergeProposals('b'), isEmpty);
      // The rest of the account's record stays.
      expect(await store.searchResultLimit('a'), 50);

      await store.setRejectedMergeProposals('a', {});
      expect(await store.rejectedMergeProposals('a'), isEmpty);
      expect(await store.searchResultLimit('a'), 50);
    });
  });

  group('the proposals', () {
    testWidgets('come from a dry run, each as its faces', (tester) async {
      final client = _MergeClient([_three, _two]);
      await _open(tester, client);

      expect(client.dryRuns, [true]);
      expect(find.byType(Card), findsNWidgets(2));
      expect(find.text('Faces: 4 → one person'), findsOneWidget);
      expect(find.text('Faces: 2 → one person'), findsOneWidget);
      expect(find.text('Merge all (2)'), findsOneWidget);
    });

    testWidgets('one is merged as shown and leaves the list', (tester) async {
      final client = _MergeClient([_three, _two]);
      await _open(tester, client);

      await tester.tap(_inCard(0, find.text('Merge')));
      await tester.pumpAndSettle();

      expect(client.combines.single.destination, '10');
      expect(client.combines.single.sources, ['11', '12']);
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Merged'), findsOneWidget);
    });

    testWidgets('a tapped face leaves its whole group out', (tester) async {
      final client = _MergeClient([_three]);
      await _open(tester, client);

      // The first face is one of the destination's two: both go.
      await tester.tap(_inCard(0, find.byType(FaceThumbnail)).first);
      await tester.pumpAndSettle();
      expect(find.text('Faces: 2 → one person'), findsOneWidget);
      expect(_inCard(0, find.byIcon(Icons.close)), findsNWidgets(2));

      await tester.tap(_inCard(0, find.text('Merge')));
      await tester.pumpAndSettle();
      // Groups of one face each: the first kept one takes the other.
      expect(client.combines.single.destination, '11');
      expect(client.combines.single.sources, ['12']);
    });

    testWidgets('with one group left there is nothing to merge', (
      tester,
    ) async {
      final client = _MergeClient([_two]);
      await _open(tester, client);

      await tester.tap(_inCard(0, find.byType(FaceThumbnail)).first);
      await tester.pumpAndSettle();

      expect(find.text('Keep at least two groups to merge.'), findsOneWidget);
      final merge = tester.widget<FilledButton>(
        _inCard(0, find.widgetWithText(FilledButton, 'Merge')),
      );
      expect(merge.onPressed, isNull);

      // Tapped again, it is back in.
      await tester.tap(_inCard(0, find.byType(FaceThumbnail)).first);
      await tester.pumpAndSettle();
      expect(find.text('Keep at least two groups to merge.'), findsNothing);
    });

    testWidgets('a turned-down proposal stays hidden until shown again', (
      tester,
    ) async {
      final client = _MergeClient([_three, _two]);
      final settings = _MemorySettings();
      await _open(tester, client, settings: settings);

      await tester.tap(_inCard(0, find.text('Not the same person')));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Hidden, turned down earlier: 1'), findsOneWidget);
      expect(client.combines, isEmpty);
      expect(settings.rejected[_session.serverId], {_three.signature});

      // Next time it is still hidden.
      await tester.pumpWidget(const SizedBox());
      await _open(tester, client, settings: settings);
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Faces: 2 → one person'), findsOneWidget);

      await tester.tap(find.text('Show again'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNWidgets(2));
      expect(settings.rejected[_session.serverId], isEmpty);
    });

    testWidgets('merging all asks, then merges each shown one as shown, and '
        'fetches the people once', (tester) async {
      final third = MergeProposal(
        destinationId: '30',
        sourceGroupIds: const ['31'],
        faces: [_face('7', '30'), _face('8', '31')],
      );
      final client = _MergeClient([_three, _two, third]);
      await _open(tester, client);

      // One turned down, one with a group left out.
      await tester.ensureVisible(_inCard(2, find.text('Not the same person')));
      await tester.pumpAndSettle();
      await tester.tap(_inCard(2, find.text('Not the same person')));
      await tester.pumpAndSettle();
      await tester.tap(_inCard(0, find.byType(FaceThumbnail)).last);
      await tester.pumpAndSettle();
      final before = client.peopleFetches;

      await tester.tap(find.text('Merge all (2)'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(client.combines, isEmpty, reason: 'not before the answer');

      await tester.tap(find.widgetWithText(FilledButton, 'Merge').last);
      await tester.pumpAndSettle();

      expect(client.dryRuns, [true], reason: 'never the server\'s real run');
      expect(
        [
          for (final c in client.combines)
            '${c.destination}<${c.sources.join(',')}',
        ],
        ['10<11', '20<21'],
      );
      expect(client.peopleFetches - before, lessThanOrEqualTo(1));
      expect(find.text('Proposals merged: 2'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('a failure halfway leaves the rest to try again', (
      tester,
    ) async {
      final client = _MergeClient([_three, _two])..failCombine = 2;
      await _open(tester, client);

      await tester.tap(find.text('Merge all (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Merge').last);
      await tester.pumpAndSettle();

      expect(client.combines, hasLength(1));
      expect(find.textContaining('Merged before the error: 1'), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect([for (final c in client.combines) c.destination], ['10', '20']);
    });

    group('naming', () {
      testWidgets('as somebody new: merged, then named, in one go', (
        tester,
      ) async {
        final client = _MergeClient([_three]);
        await _open(tester, client);

        await tester.tap(_inCard(0, find.text('Name…')));
        await tester.pumpAndSettle();
        expect(find.text('Whose face is this?'), findsOneWidget);
        // Nobody to take faces out of here.
        expect(
          find.text('Take out of this person, without a name'),
          findsNothing,
        );

        await tester.tap(find.text('New person…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Max');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(client.combines.single.destination, '10');
        expect(client.combines.single.sources, ['11', '12']);
        expect(client.renames, [(group: '10', label: 'Max')]);
        expect(client.flagged, [
          ['1', '2', '3', '4'],
        ]);
        expect(find.text('Merged as Max'), findsOneWidget);
        expect(find.byType(Card), findsNothing);
      });

      testWidgets('as somebody there is: straight into them, unnamed groups '
          'and all', (tester) async {
        final client = _MergeClient([_three]);
        await _open(tester, client);

        await tester.tap(_inCard(0, find.text('Name…')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Henrik'));
        await tester.pumpAndSettle();

        expect(client.combines.single.destination, '9');
        expect(client.combines.single.sources, ['10', '11', '12']);
        expect(client.renames, isEmpty);
        expect(find.text('Merged as Henrik'), findsOneWidget);
      });

      testWidgets('a group left out stays out when named', (tester) async {
        final client = _MergeClient([_three]);
        await _open(tester, client);

        await tester.tap(_inCard(0, find.byType(FaceThumbnail)).last);
        await tester.pumpAndSettle();
        await tester.tap(_inCard(0, find.text('Name…')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Henrik'));
        await tester.pumpAndSettle();

        expect(client.combines.single.sources, ['10', '11']);
        expect(client.flagged, [
          ['1', '2', '3'],
        ]);
      });

      testWidgets('when only the naming fails, a retry names and does not '
          'merge again', (tester) async {
        final client = _MergeClient([_two])..failRename = true;
        await _open(tester, client);

        await tester.tap(_inCard(0, find.text('Name…')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New person…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Max');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(client.combines, hasLength(1));
        expect(find.textContaining('could not be named'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(client.combines, hasLength(1));
        expect(client.renames, [(group: '20', label: 'Max')]);
        expect(find.text('Merged as Max'), findsOneWidget);
      });
    });

    group('the review list', () {
      testWidgets('a merged proposal\'s faces are flagged for it', (
        tester,
      ) async {
        final client = _MergeClient([_three, _two]);
        await _open(tester, client);

        await tester.tap(_inCard(0, find.text('Merge')));
        await tester.pumpAndSettle();

        expect(client.flagged, [
          ['1', '2', '3', '4'],
        ]);
      });

      testWidgets('merging all flags the kept faces of each, in one request', (
        tester,
      ) async {
        final client = _MergeClient([_three, _two]);
        await _open(tester, client);

        // Group 12 (face 4) left out of the first.
        await tester.tap(_inCard(0, find.byType(FaceThumbnail)).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Merge all (2)'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Merge').last);
        await tester.pumpAndSettle();

        expect(client.combines, hasLength(2));
        expect(client.flagged, [
          ['1', '2', '3', '5', '6'],
        ]);
      });

      testWidgets('a server without the flag gets no such request', (
        tester,
      ) async {
        final client = _MergeClient([_two]);
        await _open(tester, client, flag: false);

        await tester.tap(_inCard(0, find.text('Merge')));
        await tester.pumpAndSettle();

        expect(client.combines, hasLength(1));
        expect(client.flagged, isEmpty);
        expect(find.text('Merged'), findsOneWidget);
      });

      testWidgets('when only the flagging fails, a retry flags and does not '
          'merge again', (tester) async {
        final client = _MergeClient([_two])..failFlag = true;
        await _open(tester, client);

        await tester.tap(_inCard(0, find.text('Merge')));
        await tester.pumpAndSettle();

        expect(client.combines, hasLength(1));
        expect(find.byType(Card), findsNothing, reason: 'it is merged');
        expect(
          find.textContaining('Merged, but not added to the review list'),
          findsOneWidget,
        );

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(client.combines, hasLength(1));
        expect(client.flagged, [
          ['5', '6'],
        ]);
      });
    });

    testWidgets('nothing to merge says so', (tester) async {
      await _open(tester, _MergeClient([]));

      expect(
        find.text('Nothing to merge: no unnamed faces look alike enough.'),
        findsOneWidget,
      );
      expect(find.textContaining('Merge all'), findsNothing);
    });
  });

  group('the People tab', () {
    Future<void> pumpPeople(WidgetTester tester, {required bool merge}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_FixedAuth.new),
            clientProvider.overrideWithValue(_MergeClient([_two])),
            _capabilities(merge: merge),
          ],
          child: localizedApp(home: const PeopleScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers it only on a server that has it', (tester) async {
      await pumpPeople(tester, merge: false);
      expect(find.byTooltip('Merge similar unnamed'), findsNothing);
    });

    testWidgets('explains it before looking for proposals', (tester) async {
      await pumpPeople(tester, merge: true);

      await tester.tap(find.byTooltip('Merge similar unnamed'));
      await tester.pumpAndSettle();
      expect(find.textContaining('until then nothing changes'), findsOneWidget);
      expect(find.byType(MergeUnlabeledScreen), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await tester.pumpAndSettle();
      expect(find.byType(MergeUnlabeledScreen), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
    });
  });
}
