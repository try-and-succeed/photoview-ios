import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/capabilities.dart';
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

const _regina = PhotoFace(
  id: '100',
  rectangle: FaceRectangle(minX: 0.1, maxX: 0.3, minY: 0.2, maxY: 0.5),
  group: FaceGroup(id: '7', label: 'Regina', imageFaceCount: 12),
);

const _stranger = PhotoFace(
  id: '101',
  rectangle: FaceRectangle(minX: 0.6, maxX: 0.8, minY: 0.2, maxY: 0.5),
  group: FaceGroup(id: '8', imageFaceCount: 3),
);

/// Answers like the server: these faces on the photo, these people to file
/// them under, and a record of what was moved.
class _FacesClient extends PhotoviewClient {
  _FacesClient(this.faces) : super(_session);

  List<PhotoFace> faces;
  final moves = <({List<String> faces, String destination})>[];
  var asked = 0;

  @override
  Future<List<PhotoFace>> mediaFaces(
    String mediaId, {
    bool withStatus = false,
  }) async {
    asked++;
    return faces;
  }

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
    bool withStatus = false,
  }) async => offset > 0
      ? const []
      : const [
          FaceGroup(id: '7', label: 'Regina', imageFaceCount: 12),
          FaceGroup(id: '9', label: 'Anna', imageFaceCount: 5),
        ];

  @override
  Future<String?> moveImageFaces(
    List<String> imageFaceIds,
    String destinationFaceGroupId,
  ) async {
    moves.add((faces: imageFaceIds, destination: destinationFaceGroupId));
    return 'Anna';
  }

  final renames = <({String group, String? label})>[];

  /// A failure for naming alone, after the split before it went through.
  Object? failRenameWith;

  @override
  Future<String?> detachImageFaces(List<String> imageFaceIds) async => '42';

  final verifies = <({List<String> faces, bool verified})>[];

  @override
  Future<int> setImageFacesVerified(
    List<String> imageFaceIds, {
    required bool verified,
  }) async {
    verifies.add((faces: imageFaceIds, verified: verified));
    return imageFaceIds.length;
  }

  /// Holds the naming open, so the gallery can be closed while it runs.
  Completer<void>? holdRename;

  @override
  Future<String?> setFaceGroupLabel(String faceGroupId, String? label) async {
    await holdRename?.future;
    renames.add((group: faceGroupId, label: label));
    final failure = failRenameWith;
    if (failure != null) throw failure;
    return label;
  }
}

const _photo = Size(400, 300);

Future<void> _pump(
  WidgetTester tester,
  _FacesClient client, {

  /// What the system font setting does to text.
  double textScale = 1,

  /// The style text inherits there, as the app's theme sets one.
  TextStyle inherited = const TextStyle(),

  /// Whether the server knows about confirming faces.
  bool confirming = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
        serverCapabilitiesProvider.overrideWith(
          (ref) async => ServerCapabilities({
            Capability.faceVerification: confirming
                ? CapabilityState.supported
                : CapabilityState.unsupported,
          }),
        ),
      ],
      child: localizedApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.fromSize(
                size: _photo,
                child: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: DefaultTextStyle.merge(
                    style: inherited,
                    child: const PhotoFacesOverlay(mediaId: '55'),
                  ),
                ),
              ),
              // What the gallery does once it has worked out which face a
              // tap landed on.
              Consumer(
                builder: (context, ref, _) => Wrap(
                  children: [
                    for (final face in client.faces)
                      TextButton(
                        onPressed: () => assignPhotoFace(context, ref, face),
                        child: Text('assign ${face.id}'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Where a face's frame ended up, relative to the photo.
Rect _frameOf(WidgetTester tester, String name) {
  final photo = tester.getTopLeft(find.byType(PhotoFacesOverlay));
  final frames = find.descendant(
    of: find.byType(PhotoFacesOverlay),
    matching: find.byType(DecoratedBox),
  );
  final label = tester.getRect(find.text(name));

  // The frame whose left edge the name starts under.
  for (final element in frames.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    if ((rect.left - label.left).abs() < 20) return rect.shift(-photo);
  }
  throw StateError('no frame for $name');
}

void main() {
  group('PhotoFace.fromJson', () {
    test('reads the face and the person it is filed under', () {
      final face = PhotoFace.fromJson({
        'id': 100,
        'rectangle': {'minX': 0.1, 'maxX': 0.3, 'minY': 0.2, 'maxY': 0.5},
        'faceGroup': {'id': 7, 'label': null, 'imageFaceCount': 4},
      });

      expect(face.id, '100');
      expect(face.rectangle.width, closeTo(0.2, 1e-9));
      expect(face.group.id, '7');
      expect(face.group.label, isNull);
      expect(face.group.imageFaceCount, 4);
    });
  });

  testWidgets('frames each face where it is on the photo, with its name', (
    tester,
  ) async {
    await _pump(tester, _FacesClient([_regina, _stranger]));

    expect(find.text('Regina'), findsOneWidget);
    expect(find.text('3 · Unlabeled'), findsOneWidget);

    final frame = _frameOf(tester, 'Regina');
    expect(frame.left, moreOrLessEquals(0.1 * _photo.width));
    expect(frame.top, moreOrLessEquals(0.2 * _photo.height));
    expect(frame.width, moreOrLessEquals(0.2 * _photo.width));
    expect(frame.height, moreOrLessEquals(0.3 * _photo.height));
  });

  testWidgets('a name at the bottom edge goes above the face', (tester) async {
    const low = PhotoFace(
      id: '102',
      rectangle: FaceRectangle(minX: 0.1, maxX: 0.3, minY: 0.75, maxY: 1),
      group: FaceGroup(id: '7', label: 'Regina'),
    );
    await _pump(tester, _FacesClient([low]));

    final photo = tester.getRect(find.byType(PhotoFacesOverlay));
    final name = tester.getRect(find.text('Regina'));

    expect(name.bottom, lessThanOrEqualTo(photo.top + 0.75 * _photo.height));
    expect(name.top, greaterThanOrEqualTo(photo.top));
  });

  testWidgets('says so when no face was found', (tester) async {
    await _pump(tester, _FacesClient([]));

    expect(find.text('No faces were found on this photo'), findsOneWidget);
  });

  group('photoPointAt', () {
    // A photo box of 200 x 100, drawn the way the photo view draws it: at
    // its own size, centred, then scaled about its centre and shifted.
    final photo = GlobalKey();

    Future<RenderBox> pumpPhoto(
      WidgetTester tester, {
      double scale = 1,
      Offset shift = Offset.zero,
    }) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(shift.dx, shift.dy, 0, 1)
                ..scaleByDouble(scale, scale, 1, 1),
              child: SizedBox(key: photo, width: 200, height: 100),
            ),
          ),
        ),
      );
      return photo.currentContext!.findRenderObject()! as RenderBox;
    }

    /// The point on screen where the photo's own (x, y) part is drawn.
    Offset onScreen(RenderBox box, double x, double y) =>
        box.localToGlobal(Offset(x * box.size.width, y * box.size.height));

    testWidgets('maps a tap on the photo to its place on the photo', (
      tester,
    ) async {
      final box = await pumpPhoto(tester);
      final point = photoPointAt(box, onScreen(box, 0.25, 0.75))!;

      expect(point.dx, closeTo(0.25, 1e-9));
      expect(point.dy, closeTo(0.75, 1e-9));
    });

    testWidgets('follows the zoom and the shift', (tester) async {
      final box = await pumpPhoto(
        tester,
        scale: 3,
        shift: const Offset(-120, 40),
      );
      // Worked out by hand: the screen is 800 x 600, so the box's centre is
      // drawn at (400 - 120, 300 + 40); its (0.25, 0.5) lies 50 to the left
      // of that before zooming, 150 after.
      final point = photoPointAt(box, const Offset(280 - 150, 340))!;

      expect(point.dx, closeTo(0.25, 1e-9));
      expect(point.dy, closeTo(0.5, 1e-9));
    });

    testWidgets('a tap beside the photo is on no part of it', (tester) async {
      final box = await pumpPhoto(tester, scale: 2);
      expect(photoPointAt(box, const Offset(10, 10)), isNull);
    });
  });

  group('faceAt', () {
    test('finds the face under the point, with a little slack', () {
      expect(faceAt([_regina, _stranger], const Offset(0.2, 0.3)), _regina);
      expect(faceAt([_regina, _stranger], const Offset(0.31, 0.3)), _regina);
      expect(faceAt([_regina, _stranger], const Offset(0.45, 0.3)), isNull);
    });

    test('of two faces one behind the other, the smaller', () {
      const behind = PhotoFace(
        id: '200',
        rectangle: FaceRectangle(minX: 0, maxX: 0.5, minY: 0, maxY: 0.8),
        group: FaceGroup(id: '1'),
      );

      expect(faceAt([behind, _regina], const Offset(0.2, 0.3)), _regina);
      expect(faceAt([_regina, behind], const Offset(0.2, 0.3)), _regina);
    });
  });

  group('placeLabels', () {
    const area = Size(400, 300);
    const label = Size(100, 20);

    test('a name goes under its face when that is free', () {
      final boxes = placeLabels(
        frames: [const Rect.fromLTWH(50, 50, 40, 40)],
        labels: [label],
        area: area,
        gap: 4,
      );

      expect(boxes.single, const Rect.fromLTWH(50, 94, 100, 20));
    });

    test('a name does not cover the next face', () {
      // The group photo on the device: the first name ran across the face
      // beside and below it.
      final frames = [
        const Rect.fromLTWH(100, 100, 40, 40),
        const Rect.fromLTWH(160, 115, 40, 40),
      ];
      final boxes = placeLabels(
        frames: frames,
        labels: [label, label],
        area: area,
        gap: 4,
      );

      for (final (i, box) in boxes.indexed) {
        for (final (j, frame) in frames.indexed) {
          if (i != j) expect(box.overlaps(frame), isFalse, reason: '$i on $j');
        }
      }
      expect(boxes[0].overlaps(boxes[1]), isFalse);
    });

    test('two names side by side do not cover each other', () {
      final boxes = placeLabels(
        frames: [
          const Rect.fromLTWH(50, 50, 40, 40),
          const Rect.fromLTWH(110, 50, 40, 40),
        ],
        labels: [label, label],
        area: area,
        gap: 4,
      );

      expect(boxes[0].overlaps(boxes[1]), isFalse);
      expect(boxes[0].left, 50, reason: 'each starts at its own face');
      expect(boxes[1].left, 110);
    });

    test('a name at the bottom edge goes above its face', () {
      final boxes = placeLabels(
        frames: [const Rect.fromLTWH(50, 260, 40, 40)],
        labels: [label],
        area: area,
        gap: 4,
      );

      expect(boxes.single.bottom, lessThanOrEqualTo(256));
    });

    test('a face as tall as the photo still gets its name on the photo', () {
      // No room above or below: the name covers the face rather than being
      // placed off the photo, where the stack cuts it away entirely.
      final boxes = placeLabels(
        frames: [const Rect.fromLTWH(50, 0, 100, 300)],
        labels: [label],
        area: area,
        gap: 4,
      );

      expect(boxes.single.top, greaterThanOrEqualTo(0));
      expect(boxes.single.bottom, lessThanOrEqualTo(area.height));
      expect(boxes.single.size, label);
    });

    test('a name taller than the photo starts at its top', () {
      final boxes = placeLabels(
        frames: [const Rect.fromLTWH(0, 0, 40, 10)],
        labels: [const Size(40, 30)],
        area: const Size(100, 20),
        gap: 2,
      );

      expect(boxes.single.top, 0);
    });

    test('a name at the right edge is moved left to fit', () {
      final boxes = placeLabels(
        frames: [const Rect.fromLTWH(360, 50, 30, 30)],
        labels: [label],
        area: area,
        gap: 4,
      );

      expect(boxes.single.right, lessThanOrEqualTo(area.width));
      expect(boxes.single.width, label.width, reason: 'not cut short');
    });

    test('the order the server lists the faces in changes nothing', () {
      final a = const Rect.fromLTWH(100, 100, 40, 40);
      final b = const Rect.fromLTWH(160, 115, 40, 40);

      final forward = placeLabels(
        frames: [a, b],
        labels: [label, label],
        area: area,
        gap: 4,
      );
      final backward = placeLabels(
        frames: [b, a],
        labels: [label, label],
        area: area,
        gap: 4,
      );

      expect(backward, [forward[1], forward[0]]);
    });
  });

  testWidgets('on screen, no name covers another face or name', (tester) async {
    // The faces of the group photo the overlap was found on, roughly.
    const faces = [
      PhotoFace(
        id: '1',
        rectangle: FaceRectangle(
          minX: 0.20,
          maxX: 0.27,
          minY: 0.38,
          maxY: 0.48,
        ),
        group: FaceGroup(id: '1', label: 'Simone Bauer'),
      ),
      PhotoFace(
        id: '2',
        rectangle: FaceRectangle(
          minX: 0.39,
          maxX: 0.46,
          minY: 0.41,
          maxY: 0.51,
        ),
        group: FaceGroup(id: '2', label: 'Sabine Bauer'),
      ),
      PhotoFace(
        id: '3',
        rectangle: FaceRectangle(
          minX: 0.50,
          maxX: 0.57,
          minY: 0.45,
          maxY: 0.55,
        ),
        group: FaceGroup(id: '3', label: 'Tonja Lipp'),
      ),
    ];
    await _pump(tester, _FacesClient(faces));

    final photo = tester.getRect(find.byType(PhotoFacesOverlay));
    final frames = [
      for (final face in faces)
        Rect.fromLTRB(
          photo.left + face.rectangle.minX * photo.width,
          photo.top + face.rectangle.minY * photo.height,
          photo.left + face.rectangle.maxX * photo.width,
          photo.top + face.rectangle.maxY * photo.height,
        ),
    ];
    final names = [
      for (final face in faces)
        tester.getRect(
          find.ancestor(
            of: find.text(face.group.label!),
            matching: find.byType(Container),
          ),
        ),
    ];

    for (final (i, name) in names.indexed) {
      for (final (j, frame) in frames.indexed) {
        if (i != j) {
          expect(name.overlaps(frame), isFalse, reason: 'name $i on face $j');
        }
      }
      for (final (j, other) in names.indexed) {
        if (i < j) {
          expect(name.overlaps(other), isFalse, reason: 'name $i on name $j');
        }
      }
    }
  });

  testWidgets('the names keep their size to the photo, whatever the font '
      'setting', (tester) async {
    // They label the photo, so they are measured in parts of it. Scaled by the
    // system setting they would outgrow the boxes measured for them, and
    // cover the faces the placing kept them off.
    Future<Rect> nameAt(double scale) async {
      await _pump(tester, _FacesClient([_regina]), textScale: scale);
      return tester.getRect(
        find.ancestor(
          of: find.text('Regina'),
          matching: find.byType(Container),
        ),
      );
    }

    final normal = await nameAt(1);
    final large = await nameAt(2);

    expect(large.size, normal.size);
    expect(
      find.descendant(
        of: find.byType(PhotoFacesOverlay),
        matching: find.byType(RichText),
      ),
      findsOneWidget,
    );
    final text = tester.widget<RichText>(
      find.descendant(
        of: find.byType(PhotoFacesOverlay),
        matching: find.byType(RichText),
      ),
    );
    expect(text.textScaler, TextScaler.noScaling);
  });

  testWidgets('a name is shown whole, in the style it inherits', (
    tester,
  ) async {
    // Found on the device: measured without the theme's font and spacing,
    // every name came out narrower than drawn and ended in "…".
    await _pump(
      tester,
      _FacesClient([_regina]),
      inherited: const TextStyle(letterSpacing: 4),
    );

    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(PhotoFacesOverlay),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('the frames take no taps of their own', (tester) async {
    // The photo view under them claims the taps; frames that took them would
    // be fighting it for each one.
    await _pump(tester, _FacesClient([_regina]));

    expect(
      find.descendant(
        of: find.byType(PhotoFacesOverlay),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });

  testWidgets('a tapped face is filed elsewhere, after the question', (
    tester,
  ) async {
    final client = _FacesClient([_regina, _stranger]);
    await _pump(tester, client);

    await tester.tap(find.text('assign 101'));
    await tester.pumpAndSettle();

    expect(find.text('Whose face is this?'), findsOneWidget);
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(
      find.text('Move 1 photo from 3 · Unlabeled to Anna?'),
      findsOneWidget,
    );
    expect(client.moves, isEmpty, reason: 'not before the answer');

    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    // That face alone — not Regina's, which is on the same photo.
    expect(client.moves.single.faces, ['101']);
    expect(client.moves.single.destination, '9');
    expect(find.text('Moved to Anna'), findsOneWidget);
  });

  testWidgets('a face filed under a new person whose naming fails can be '
      'named on retry', (tester) async {
    // As on a person's page: the face is out already, and the retry is the
    // only way left to give the new person its name.
    final client = _FacesClient([_regina, _stranger])
      ..failRenameWith = Exception('offline');
    await _pump(tester, client);

    await tester.tap(find.text('assign 101'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New person…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Max');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    client.failRenameWith = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(client.renames, [
      (group: '42', label: 'Max'),
      (group: '42', label: 'Max'),
    ]);
  });

  testWidgets('the answer arrives when the gallery was closed meanwhile', (
    tester,
  ) async {
    // The face went out, the naming failed after the gallery was left. That
    // message is the only word on where the photo now is.
    final client = _FacesClient([_regina, _stranger])
      ..failRenameWith = Exception('offline')
      ..holdRename = Completer<void>();
    await _pump(tester, client);

    await tester.tap(find.text('assign 101'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New person…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Max');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pump();

    // The gallery goes; the app around it, and its messenger, stay.
    await tester.pumpWidget(
      ProviderScope(
        // The same overrides as before: the scope stays, and Riverpod does
        // not take a changed list of them.
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
          serverCapabilitiesProvider.overrideWith(
            (ref) async => ServerCapabilities({
              Capability.faceVerification: CapabilityState.unsupported,
            }),
          ),
        ],
        child: localizedApp(
          home: const Scaffold(body: Center(child: Text('gone'))),
        ),
      ),
    );
    client.holdRename!.complete();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('The photos are with a new, unnamed person'),
      findsOneWidget,
    );
  });

  testWidgets('the person a face is filed under is not offered for it', (
    tester,
  ) async {
    await _pump(tester, _FacesClient([_regina]));

    await tester.tap(find.text('assign 100'));
    await tester.pumpAndSettle();

    final list = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: list, matching: find.text('Regina')),
      findsNothing,
    );
    expect(
      find.descendant(of: list, matching: find.text('Anna')),
      findsOneWidget,
    );
  });

  group('keeping a face as a person of their own', () {
    testWidgets('an unnamed face is kept at once, without a question', (
      tester,
    ) async {
      final client = _FacesClient([_regina, _stranger]);
      await _pump(tester, client, confirming: true);

      await tester.tap(find.text('assign 101'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep as a person of their own'));
      await tester.pumpAndSettle();

      expect(client.verifies.single.faces, ['101']);
      expect(client.verifies.single.verified, isTrue);
      expect(client.moves, isEmpty);
      expect(find.text('Face kept as a person of their own'), findsOneWidget);
    });

    testWidgets('a kept one can be let go again', (tester) async {
      final client = _FacesClient([
        const PhotoFace(
          id: '101',
          rectangle: FaceRectangle(minX: 0.6, maxX: 0.8, minY: 0.2, maxY: 0.5),
          group: FaceGroup(id: '8', imageFaceCount: 3),
          verified: true,
        ),
      ]);
      await _pump(tester, client, confirming: true);

      await tester.tap(find.text('assign 101'));
      await tester.pumpAndSettle();
      expect(find.text('Keep as a person of their own'), findsNothing);
      await tester.tap(find.text('No longer keep as a person of their own'));
      await tester.pumpAndSettle();

      expect(client.verifies.single.faces, ['101']);
      expect(client.verifies.single.verified, isFalse);
      expect(find.text('Confirmation taken back'), findsOneWidget);
    });

    testWidgets('not offered for a named face', (tester) async {
      await _pump(tester, _FacesClient([_regina, _stranger]), confirming: true);
      await tester.tap(find.text('assign 100'));
      await tester.pumpAndSettle();
      expect(find.textContaining('person of their own'), findsNothing);
    });

    testWidgets('not offered without the capability', (tester) async {
      await _pump(tester, _FacesClient([_regina, _stranger]));
      await tester.tap(find.text('assign 101'));
      await tester.pumpAndSettle();
      expect(find.textContaining('person of their own'), findsNothing);
    });
  });

  testWidgets('after a move the names are asked for again', (tester) async {
    final client = _FacesClient([_regina, _stranger]);
    await _pump(tester, client);
    final before = client.asked;

    client.faces = [
      _regina,
      const PhotoFace(
        id: '101',
        rectangle: FaceRectangle(minX: 0.6, maxX: 0.8, minY: 0.2, maxY: 0.5),
        group: FaceGroup(id: '9', label: 'Anna', imageFaceCount: 6),
      ),
    ];
    await tester.tap(find.text('assign 101'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    expect(client.asked, greaterThan(before));
    expect(
      find.descendant(
        of: find.byType(PhotoFacesOverlay),
        matching: find.text('Anna'),
      ),
      findsOneWidget,
    );
  });
}
