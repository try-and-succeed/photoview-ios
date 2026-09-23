import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/person_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/widgets/media_grid.dart';

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

/// Records what the screen sends, and answers as the server does.
class _FacesClient extends PhotoviewClient {
  _FacesClient({required this.photos, required this.people})
    : super(_session);

  final List<PersonPhoto> photos;
  final List<FaceGroup> people;

  final moves = <({List<String> faces, String destination})>[];
  final detaches = <List<String>>[];

  Object? failWith;

  @override
  Future<List<PersonPhoto>> personPhotos(String faceGroupId) async => photos;

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
  }) async => people.skip(offset).take(limit).toList();

  @override
  Future<String?> moveImageFaces(
    List<String> imageFaceIds,
    String destinationFaceGroupId,
  ) async {
    moves.add((faces: imageFaceIds, destination: destinationFaceGroupId));
    final failure = failWith;
    if (failure != null) throw failure;
    return 'Anna';
  }

  @override
  Future<String?> detachImageFaces(List<String> imageFaceIds) async {
    detaches.add(imageFaceIds);
    final failure = failWith;
    if (failure != null) throw failure;
    return '42';
  }
}

PersonPhoto _photo(String mediaId, List<String> faceIds, {String? title}) =>
    PersonPhoto(
      media: MediaItem(
        id: mediaId,
        type: MediaType.photo,
        title: title ?? '$mediaId.jpg',
      ),
      faceIds: faceIds,
    );

Future<void> _open(WidgetTester tester, _FacesClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
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

/// Starts the picking mode on the first tile.
Future<void> _pickFirst(WidgetTester tester) async {
  await tester.longPress(find.byType(MediaThumbnail).first);
  await tester.pumpAndSettle();
}

void main() {
  final anna = const FaceGroup(id: '9', label: 'Anna', imageFaceCount: 5);

  testWidgets('a long press starts picking, as in the album', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10']), _photo('2', ['11'])],
      people: [anna],
    );
    await _open(tester, client);

    expect(find.text('Regina'), findsOneWidget);

    await _pickFirst(tester);

    expect(find.text('Selected: 1'), findsOneWidget);
  });

  testWidgets('moving sends the face ids, not the media ids', (tester) async {
    // `moveImageFaces` takes `imageFace` rows; a media id means nothing to it.
    final client = _FacesClient(
      photos: [_photo('1', ['10']), _photo('2', ['11'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(client.moves.single.faces, ['10']);
    expect(client.moves.single.destination, '9');
    expect(find.textContaining('Moved to Anna'), findsOneWidget);
  });

  testWidgets('the picker asks the question it was opened for', (tester) async {
    // The same list serves two actions. Found on the device: moving a photo
    // opened a dialog headed "choose the person to merge in", which is not
    // what the tap was about and would have been read as the wrong action.
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();

    expect(find.text('Choose the person to move them to'), findsOneWidget);
    expect(find.text('Choose the person to merge in'), findsNothing);
  });

  testWidgets('a photo this person is in twice moves whole', (tester) async {
    // The tile stands for the photo's faces in this group. Leaving one behind
    // would file half a photo under somebody else.
    final client = _FacesClient(
      photos: [_photo('1', ['10', '11'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(client.moves.single.faces, ['10', '11']);
  });

  testWidgets('detaching sends the ticked faces and says so', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10']), _photo('2', ['11'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.call_split));
    await tester.pumpAndSettle();

    expect(client.detaches, [
      ['10'],
    ]);
    expect(find.textContaining('Split off'), findsOneWidget);
  });

  testWidgets('picking ends once the photos are somebody else\'s', (
    tester,
  ) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10']), _photo('2', ['11'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.call_split));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 1'), findsNothing);
    expect(find.text('Regina'), findsOneWidget, reason: 'back to the person');
  });

  testWidgets('back leaves the picking mode, not the person', (tester) async {
    // Losing a selection to a stray swipe is the kind of thing nobody tries
    // twice — the album settled this already.
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(popped, isTrue, reason: 'the gesture was taken');
    expect(find.text('Selected: 1'), findsNothing);
    expect(find.text('Regina'), findsOneWidget);
  });

  testWidgets('select all ticks every photo there is', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10']), _photo('2', ['11']), _photo('3', ['12'])],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 3'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_split));
    await tester.pumpAndSettle();

    expect(client.detaches, [
      ['10', '11', '12'],
    ]);
  });

  testWidgets('a retried move sends the same faces, with no second dialog', (
    tester,
  ) async {
    // The rule the naming action already follows: a retry repeats the
    // sending, not the asking. The user has ticked photos and picked a
    // person, and has then been asked about a certificate they did not
    // expect — being sent back to the dialog is losing that work. The ids
    // come from the moment of the decision, not from a selection that may
    // have been changed while the question was up.
    //
    // The probe finds nothing here — a widget test has no socket — which is
    // the outcome that tries the action again.
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    )..failWith = CertificateNotTrustedException(_session.endpoint);

    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(client.moves, hasLength(1), reason: 'the first attempt failed');
    expect(find.text('Review certificate'), findsOneWidget);

    client.failWith = null;
    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(client.moves, hasLength(2));
    expect(client.moves.last.faces, ['10']);
    expect(client.moves.last.destination, '9');
    expect(
      find.text('Choose the person to move them to'),
      findsNothing,
      reason: 'no second dialog',
    );
  });

  testWidgets('a retried split sends the same faces', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    )..failWith = CertificateNotTrustedException(_session.endpoint);

    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.call_split));
    await tester.pumpAndSettle();

    expect(client.detaches, hasLength(1));

    client.failWith = null;
    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(client.detaches, [
      ['10'],
      ['10'],
    ]);
  });

  testWidgets('a refused move is reported, not swallowed', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    )..failWith = const ApiException('Could not reach the server');
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not move the photos'), findsOneWidget);
  });

  testWidgets('a refused split is reported, not swallowed', (tester) async {
    final client = _FacesClient(
      photos: [_photo('1', ['10'])],
      people: [anna],
    )..failWith = const ApiException('Could not reach the server');
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.call_split));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not split them off'), findsOneWidget);
  });
}
