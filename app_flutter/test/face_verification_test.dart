import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/person_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
import 'package:photoview/widgets/media_grid.dart';
import 'package:photoview/widgets/photo_faces.dart';

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

const _henrik = FaceGroup(id: '9', label: 'Henrik', imageFaceCount: 4);

/// Answers as a server that knows about confirming, and records what the
/// screens send.
class _VerifyClient extends PhotoviewClient {
  _VerifyClient({this.photos = const [], this.faces = const []})
    : super(_session);

  final List<PersonPhoto> photos;
  List<PhotoFace> faces;

  /// What `withStatus` each fetch of a person's photos asked with.
  final photoFetches = <bool>[];
  final faceVerifies = <({List<String> ids, bool verified})>[];
  final mediaVerifies = <({List<String> ids, bool verified})>[];

  /// `dryRun` of each re-identification, in order.
  final reclassifyRuns = <bool>[];

  ReclassifyResult preview = const ReclassifyResult();
  ReclassifyResult done = const ReclassifyResult();

  @override
  Future<List<PersonPhoto>> personPhotos(
    String faceGroupId, {
    bool withStatus = false,
  }) async {
    photoFetches.add(withStatus);
    return photos;
  }

  @override
  Future<List<PhotoFace>> mediaFaces(
    String mediaId, {
    bool withStatus = false,
  }) async => faces;

  @override
  Future<int> setImageFacesVerified(
    List<String> imageFaceIds, {
    required bool verified,
  }) async {
    faceVerifies.add((ids: imageFaceIds, verified: verified));
    return imageFaceIds.length;
  }

  @override
  Future<int> setMediaFacesVerified(
    List<String> mediaIds, {
    required bool verified,
  }) async {
    mediaVerifies.add((ids: mediaIds, verified: verified));
    return mediaIds.length;
  }

  @override
  Future<ReclassifyResult> reclassifyFaceGroups(
    List<String> faceGroupIds, {
    required bool dryRun,
  }) async {
    reclassifyRuns.add(dryRun);
    return dryRun ? preview : done;
  }

  @override
  Future<List<MediaItem>> mediaNeedingReview({
    required int limit,
    required int offset,
  }) async => const [];
}

PersonPhoto _photo(
  String mediaId,
  List<String> faceIds, {
  bool verified = false,
  bool needsReview = false,
}) => PersonPhoto(
  media: MediaItem(id: mediaId, type: MediaType.photo, title: '$mediaId.jpg'),
  faceIds: faceIds,
  verified: verified,
  needsReview: needsReview,
);

Override _capability(bool supported) => serverCapabilitiesProvider.overrideWith(
  (ref) async => ServerCapabilities({
    Capability.faceVerification: supported
        ? CapabilityState.supported
        : CapabilityState.unsupported,
  }),
);

Future<void> _openPerson(
  WidgetTester tester,
  _VerifyClient client, {
  bool supported = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
        _capability(supported),
      ],
      child: localizedApp(
        home: const PersonScreen(
          faceGroup: FaceGroup(id: '7', label: 'Regina', imageFaceCount: 3),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Three photos: one confirmed, one waiting for review, one neither — the
/// first of them with two faces of the person on it.
final _three = [
  _photo('3', ['30', '31']),
  _photo('1', ['10'], verified: true),
  _photo('2', ['20'], needsReview: true),
];

void main() {
  group('person page', () {
    testWidgets('a server without confirming gets neither filters nor '
        're-identifying', (tester) async {
      final client = _VerifyClient(photos: _three);
      await _openPerson(tester, client, supported: false);

      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byTooltip('Re-identify'), findsNothing);
      expect(client.photoFetches, everyElement(isFalse));
    });

    testWidgets('asks for the flags once the server is known to have them', (
      tester,
    ) async {
      final client = _VerifyClient(photos: _three);
      await _openPerson(tester, client);

      expect(client.photoFetches.last, isTrue);
    });

    testWidgets('the filters count their photos and narrow the grid', (
      tester,
    ) async {
      await _openPerson(tester, _VerifyClient(photos: _three));

      expect(find.text('3 · All'), findsOneWidget);
      expect(find.text('1 · Confirmed'), findsOneWidget);
      expect(find.text('2 · Unconfirmed'), findsOneWidget);
      expect(find.text('1 · To review'), findsOneWidget);
      expect(find.byType(MediaThumbnail), findsNWidgets(3));

      await tester.tap(find.text('1 · Confirmed'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaThumbnail), findsOneWidget);

      await tester.tap(find.text('2 · Unconfirmed'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaThumbnail), findsNWidgets(2));
    });

    testWidgets('confirming ticked photos sends all of this person\'s faces '
        'on them', (tester) async {
      final client = _VerifyClient(photos: _three);
      await _openPerson(tester, client);

      await tester.longPress(find.byType(MediaThumbnail).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Confirm'));
      await tester.pumpAndSettle();

      expect(client.faceVerifies, hasLength(1));
      expect(client.faceVerifies.single.ids, ['30', '31']);
      expect(client.faceVerifies.single.verified, isTrue);
      expect(find.text('Photos confirmed: 1'), findsOneWidget);
    });

    testWidgets('with only confirmed photos ticked it takes the confirmation '
        'back', (tester) async {
      final client = _VerifyClient(photos: _three);
      await _openPerson(tester, client);

      await tester.longPress(find.byType(MediaThumbnail).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Take back the confirmation'));
      await tester.pumpAndSettle();

      expect(client.faceVerifies.single.ids, ['10']);
      expect(client.faceVerifies.single.verified, isFalse);
    });

    testWidgets('changing the filter drops the ticks', (tester) async {
      final client = _VerifyClient(photos: _three);
      await _openPerson(tester, client);

      await tester.longPress(find.byType(MediaThumbnail).first);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);

      await tester.tap(find.text('2 · Unconfirmed'));
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsNothing);
    });

    group('re-identifying', () {
      _VerifyClient client() => _VerifyClient(photos: _three)
        ..preview = const ReclassifyResult(
          checked: 5,
          kept: 1,
          moved: 3,
          unmatched: 1,
          verifiedSamples: 40,
          changes: [
            FaceReassignment(faceId: '1', from: FaceGroup(id: '7'), to: _henrik),
            FaceReassignment(faceId: '2', from: FaceGroup(id: '7'), to: _henrik),
            FaceReassignment(faceId: '3', from: FaceGroup(id: '7'), to: _henrik),
            FaceReassignment(faceId: '4', from: FaceGroup(id: '7')),
          ],
        )
        ..done = const ReclassifyResult(checked: 5, moved: 3);

      testWidgets('shows the dry run and sends nothing more on cancel', (
        tester,
      ) async {
        final c = client();
        await _openPerson(tester, c);

        await tester.tap(find.byTooltip('Re-identify'));
        await tester.pumpAndSettle();

        expect(c.reclassifyRuns, [true]);
        expect(find.text('Unconfirmed faces of Regina: 5'), findsOneWidget);
        expect(
          find.text('Compared with confirmed faces of all people: 40'),
          findsOneWidget,
        );
        expect(find.text('Stay with Regina: 1'), findsOneWidget);
        expect(find.text('Go to other people: 3'), findsOneWidget);
        expect(find.text('Henrik: 3'), findsOneWidget);
        expect(
          find.text('No match, each becomes a new person: 1'),
          findsOneWidget,
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(c.reclassifyRuns, [true]);
      });

      testWidgets('a yes to the preview runs it once for real', (
        tester,
      ) async {
        final c = client();
        await _openPerson(tester, c);

        await tester.tap(find.byTooltip('Re-identify'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Re-identify'));
        await tester.pumpAndSettle();

        expect(c.reclassifyRuns, [true, false]);
        expect(
          find.text('Re-identified. Faces to review: 5'),
          findsOneWidget,
        );
        expect(find.widgetWithText(SnackBarAction, 'Review'), findsOneWidget);
      });

      testWidgets('with nothing unconfirmed there is no question', (
        tester,
      ) async {
        final c = _VerifyClient(photos: _three);
        await _openPerson(tester, c);

        await tester.tap(find.byTooltip('Re-identify'));
        await tester.pumpAndSettle();

        expect(c.reclassifyRuns, [true]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text(
            'Every face of this person is confirmed; there is nothing to '
            're-identify.',
          ),
          findsOneWidget,
        );
      });
    });
  });

  group('photo view', () {
    const unconfirmed = PhotoFace(
      id: '100',
      rectangle: FaceRectangle(minX: 0.1, maxX: 0.3, minY: 0.2, maxY: 0.5),
      group: FaceGroup(id: '7', label: 'Regina'),
    );
    const confirmed = PhotoFace(
      id: '101',
      rectangle: FaceRectangle(minX: 0.6, maxX: 0.8, minY: 0.2, maxY: 0.5),
      group: FaceGroup(id: '9', label: 'Henrik'),
      verified: true,
    );

    Future<void> pumpButton(
      WidgetTester tester,
      _VerifyClient client, {
      bool supported = true,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_FixedAuth.new),
            clientProvider.overrideWithValue(client),
            _capability(supported),
          ],
          child: localizedApp(
            home: Scaffold(
              appBar: AppBar(
                actions: const [VerifyPhotoFacesButton(mediaId: '55')],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('confirms every face on the photo', (tester) async {
      final client = _VerifyClient(faces: [unconfirmed, confirmed]);
      await pumpButton(tester, client);

      await tester.tap(find.byTooltip('Everyone on this photo is right'));
      await tester.pumpAndSettle();

      expect(client.mediaVerifies.single.ids, ['55']);
      expect(client.mediaVerifies.single.verified, isTrue);
      expect(find.text('Faces on this photo confirmed'), findsOneWidget);
    });

    testWidgets('takes it back once every face is confirmed', (tester) async {
      final client = _VerifyClient(faces: [confirmed]);
      await pumpButton(tester, client);

      await tester.tap(find.byTooltip('Take back the confirmation'));
      await tester.pumpAndSettle();

      expect(client.mediaVerifies.single.verified, isFalse);
    });

    testWidgets('is not offered without faces or without the capability', (
      tester,
    ) async {
      await pumpButton(tester, _VerifyClient(faces: [unconfirmed]),
          supported: false);
      expect(find.byType(IconButton), findsNothing);

      await pumpButton(tester, _VerifyClient());
      expect(find.byType(IconButton), findsNothing);
    });

    test('frames say whether a face is confirmed or waits for review', () {
      expect(faceStatusColor(confirmed), Colors.lightGreenAccent);
      expect(
        faceStatusColor(
          const PhotoFace(
            id: '1',
            rectangle: FaceRectangle(minX: 0, maxX: 1, minY: 0, maxY: 1),
            group: FaceGroup(id: '1'),
            needsReview: true,
          ),
        ),
        Colors.amberAccent,
      );
      expect(faceStatusColor(unconfirmed), Colors.white);
    });
  });

  group('reading the server', () {
    test('a tile is confirmed only when all of its faces are, and up for '
        'review when any is', () {
      Map<String, dynamic> face(String id, String media, {bool? v, bool? r}) => {
        'id': id,
        'verified': ?v,
        'needsReview': ?r,
        'media': {'id': media, 'type': 'Photo', 'title': '$media.jpg'},
      };

      final photos = personPhotosFrom({
        'imageFaces': [
          face('1', 'a', v: true, r: false),
          face('2', 'a', v: false, r: true),
          face('3', 'b', v: true, r: false),
          // A server without the flags sends neither.
          face('4', 'c'),
        ],
      });
      final byId = {for (final p in photos) p.media.id: p};

      expect(byId['a']!.verified, isFalse);
      expect(byId['a']!.needsReview, isTrue);
      expect(byId['b']!.verified, isTrue);
      expect(byId['b']!.needsReview, isFalse);
      expect(byId['c']!.verified, isFalse);
      expect(byId['c']!.needsReview, isFalse);
    });

    test('a face says whether it is confirmed and waits for review', () {
      final face = PhotoFace.fromJson({
        'id': '5',
        'verified': true,
        'needsReview': false,
        'rectangle': {'minX': 0, 'maxX': 1, 'minY': 0, 'maxY': 1},
        'faceGroup': {'id': '7'},
      });
      expect(face.verified, isTrue);
      expect(face.needsReview, isFalse);
    });

    test('a dry run counts the faces per destination, most first, without '
        'the unmatched', () {
      final result = ReclassifyResult.fromJson({
        'checked': 4,
        'changes': [
          for (final to in ['9', '9', '12', null])
            {
              'imageFace': {'id': 'x'},
              'from': {'id': '7', 'label': 'Meike'},
              'to': to == null ? null : {'id': to, 'label': 'P$to'},
            },
        ],
      });

      expect(result.checked, 4);
      expect([
        for (final d in result.destinations) (d.person.id, d.count),
      ], [('9', 2), ('12', 1)]);
    });

    test('the probe settles the capability either way', () {
      expect(
        readProbe(
          data: {'faceVerification': <dynamic>[]},
        )[Capability.faceVerification],
        CapabilityState.supported,
      );
      expect(
        readProbe(
          errorMessages: [
            'Cannot query field "verifiedFaceCount" on type "FaceGroup".',
          ],
        )[Capability.faceVerification],
        CapabilityState.unsupported,
      );
    });
  });
}
