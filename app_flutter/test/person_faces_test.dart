import 'dart:async';

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

  /// Signed in elsewhere, as the settings' server switch does it.
  void switchTo(Session other) => state = AsyncData(other);
}

/// Records what the screen sends, and answers as the server does.
class _FacesClient extends PhotoviewClient {
  _FacesClient({required this.photos, required this.people}) : super(_session);

  final List<PersonPhoto> photos;
  final List<FaceGroup> people;

  final moves = <({List<String> faces, String destination})>[];
  final detaches = <List<String>>[];
  final renames = <({String group, String? label})>[];

  Object? failWith;

  /// A failure for naming alone, after the split before it went through.
  Object? failRenameWith;

  /// Holds the naming open, so the screen can be left while it runs.
  Completer<void>? holdRename;

  @override
  Future<String?> setFaceGroupLabel(String faceGroupId, String? label) async {
    await holdRename?.future;
    renames.add((group: faceGroupId, label: label));
    final failure = failRenameWith;
    if (failure != null) throw failure;
    return label;
  }

  @override
  Future<List<PersonPhoto>> personPhotos(
    String faceGroupId, {
    bool withStatus = false,
  }) async => photos;

  /// The offsets of the pages of people asked for, in order.
  final pageOffsets = <int>[];

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
  }) async {
    pageOffsets.add(offset);
    return people.skip(offset).take(limit).toList();
  }

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

  /// Runs while the faces are being taken out, before the answer.
  void Function()? whileDetaching;

  @override
  Future<String?> detachImageFaces(List<String> imageFaceIds) async {
    whileDetaching?.call();
    detaches.add(imageFaceIds);
    final failure = failWith;
    if (failure != null) throw failure;
    return createdGroup;
  }

  /// The id of the group a split makes, or null for a server that names none.
  String? createdGroup = '42';
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

/// Says yes to the question asked before photos move.
Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Move'));
  await tester.pumpAndSettle();
}

/// Moves the ticked photos to [name], answering the question on the way.
Future<void> _moveTo(WidgetTester tester, String name) async {
  await tester.tap(find.byIcon(Icons.person_add_alt));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  await _confirm(tester);
}

/// Splits the ticked photos off, answering the question on the way.
Future<void> _split(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.call_split));
  await tester.pumpAndSettle();
  await _confirm(tester);
}

/// Signs in to another server, as the settings' server switch does.
void _signInElsewhere(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(PersonScreen)),
  );
  (container.read(authProvider.notifier) as _FixedAuth).switchTo(
    Session(
      endpoint: Uri.parse('https://elsewhere/api/graphql'),
      token: 'other',
      username: 'someone',
    ),
  );
}

void main() {
  final anna = const FaceGroup(id: '9', label: 'Anna', imageFaceCount: 5);

  group('a retry after a sign-in elsewhere sends nothing', () {
    // The ids belong to the account the action started on. Every request
    // goes to whoever is signed in when it runs, so a retry after a switch
    // would move, split or name whatever has those ids on the other server.
    testWidgets('a move', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failWith = CertificateNotTrustedException(_session.endpoint);
      await _open(tester, client);
      await _pickFirst(tester);
      await _moveTo(tester, 'Anna');
      expect(client.moves, hasLength(1), reason: 'the first attempt failed');

      client.failWith = null;
      _signInElsewhere(tester);
      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(client.moves, hasLength(1));
    });

    testWidgets('a split', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failWith = CertificateNotTrustedException(_session.endpoint);
      await _open(tester, client);
      await _pickFirst(tester);
      await _split(tester);
      expect(client.detaches, hasLength(1), reason: 'the first attempt failed');

      client.failWith = null;
      _signInElsewhere(tester);
      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(client.detaches, hasLength(1));
    });

    testWidgets('a move to a new person whose split failed', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failWith = Exception('offline');
      await _open(tester, client);
      await _pickFirst(tester);
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);
      expect(client.detaches, hasLength(1), reason: 'the first attempt failed');

      client.failWith = null;
      _signInElsewhere(tester);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(client.detaches, hasLength(1));
      expect(client.renames, isEmpty);
    });
  });

  testWidgets('a long press starts picking, as in the album', (tester) async {
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
        _photo('2', ['11']),
      ],
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
      photos: [
        _photo('1', ['10']),
        _photo('2', ['11']),
      ],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await _moveTo(tester, 'Anna');

    expect(client.moves.single.faces, ['10']);
    expect(client.moves.single.destination, '9');
    expect(find.textContaining('Moved to Anna'), findsOneWidget);
  });

  testWidgets('the picker asks the question it was opened for', (tester) async {
    // The same list serves two actions. Found on the device: moving a photo
    // opened a dialog headed "choose the person to merge in", which is not
    // what the tap was about and would have been read as the wrong action.
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
      ],
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
      photos: [
        _photo('1', ['10', '11']),
      ],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await _moveTo(tester, 'Anna');

    expect(client.moves.single.faces, ['10', '11']);
  });

  testWidgets('detaching sends the ticked faces and says so', (tester) async {
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
        _photo('2', ['11']),
      ],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await _split(tester);

    expect(client.detaches, [
      ['10'],
    ]);
    expect(find.textContaining('Split off'), findsOneWidget);
  });

  testWidgets('picking ends once the photos are somebody else\'s', (
    tester,
  ) async {
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
        _photo('2', ['11']),
      ],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await _split(tester);

    expect(find.text('Selected: 1'), findsNothing);
    expect(find.text('Regina'), findsOneWidget, reason: 'back to the person');
  });

  testWidgets('back leaves the picking mode, not the person', (tester) async {
    // Losing a selection to a stray swipe is the kind of thing nobody tries
    // twice — the album settled this already.
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
      ],
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
      photos: [
        _photo('1', ['10']),
        _photo('2', ['11']),
        _photo('3', ['12']),
      ],
      people: [anna],
    );
    await _open(tester, client);
    await _pickFirst(tester);

    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 3'), findsOneWidget);

    await _split(tester);

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
      photos: [
        _photo('1', ['10']),
      ],
      people: [anna],
    )..failWith = CertificateNotTrustedException(_session.endpoint);

    await _open(tester, client);
    await _pickFirst(tester);

    await _moveTo(tester, 'Anna');

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
      photos: [
        _photo('1', ['10']),
      ],
      people: [anna],
    )..failWith = CertificateNotTrustedException(_session.endpoint);

    await _open(tester, client);
    await _pickFirst(tester);

    await _split(tester);

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
      photos: [
        _photo('1', ['10']),
      ],
      people: [anna],
    )..failWith = const ApiException('Could not reach the server');
    await _open(tester, client);
    await _pickFirst(tester);

    await _moveTo(tester, 'Anna');

    expect(find.textContaining('Could not move the photos'), findsOneWidget);
  });

  group('asked before it happens', () {
    // The icons do not say what they do. The question does, in words, and
    // nothing is sent until it is answered yes.
    testWidgets('a move names how many, from whom and to whom', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
          _photo('2', ['11', '12']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anna'));
      await tester.pumpAndSettle();

      // Two photos, though there are three faces behind them.
      expect(find.text('Move 2 photos from Regina to Anna?'), findsOneWidget);
      expect(client.moves, isEmpty, reason: 'not before the answer');

      await _confirm(tester);
      expect(client.moves.single.faces, ['10', '11', '12']);
    });

    testWidgets('cancelling a move sends nothing', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anna'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(client.moves, isEmpty);
      expect(find.text('Selected: 1'), findsOneWidget, reason: 'still picked');
    });

    testWidgets('a split says where the photos end up', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.call_split));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Take 1 photo out of Regina? It will show under “Unlabeled”.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(client.detaches, isEmpty);
    });

    testWidgets('a retried move does not ask again', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failWith = CertificateNotTrustedException(_session.endpoint);
      await _open(tester, client);
      await _pickFirst(tester);
      await _moveTo(tester, 'Anna');

      client.failWith = null;
      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(client.moves, hasLength(2));
      expect(find.text('Move photos?'), findsNothing);
    });
  });

  group('the move dialog', () {
    testWidgets('offers a new person, which is named before anything is sent', (
      tester,
    ) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Max ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Move 1 photo from Regina to Max?'), findsOneWidget);
      expect(client.detaches, isEmpty, reason: 'not before the answer');

      await _confirm(tester);

      expect(client.detaches, [
        ['10'],
      ]);
      expect(client.renames.single, (group: '42', label: 'Max'));
      expect(find.text('Moved to Max'), findsOneWidget);
    });

    testWidgets('a new person without a name is not made', (tester) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(client.detaches, isEmpty);
      expect(find.text('Move photos?'), findsNothing);
    });

    testWidgets('a failed naming is retried on the person already made', (
      tester,
    ) async {
      // The split went through, the name did not. Splitting again would
      // leave an unnamed group behind and name a second one.
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failRenameWith = CertificateNotTrustedException(_session.endpoint);
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      client.failRenameWith = null;
      await tester.tap(find.text('Review certificate'));
      await tester.pumpAndSettle();

      expect(client.detaches, hasLength(1), reason: 'split once');
      expect(client.renames, [
        (group: '42', label: 'Max'),
        (group: '42', label: 'Max'),
      ]);
    });

    testWidgets('a naming that fails for any reason can still be retried', (
      tester,
    ) async {
      // Not a certificate: the server is simply unreachable for a moment.
      // The photos are out of this person already and cannot be ticked again,
      // so the retry is the only way left to give the new person its name.
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failRenameWith = Exception('offline');
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(
        find.textContaining('The photos are with a new, unnamed person'),
        findsOneWidget,
        reason: 'says where the photos are',
      );

      client.failRenameWith = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(client.detaches, hasLength(1), reason: 'split once');
      expect(client.renames, [
        (group: '42', label: 'Max'),
        (group: '42', label: 'Max'),
      ]);
      expect(find.text('Moved to Max'), findsOneWidget);
    });

    testWidgets('a new person is not named on an account signed in to since', (
      tester,
    ) async {
      // The group id belongs to the first server. Sent to the second, it
      // would rename whatever group has that id there.
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      client.whileDetaching = () => _signInElsewhere(tester);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(client.detaches, hasLength(1));
      expect(client.renames, isEmpty);
      expect(
        find.textContaining('signed in to another account'),
        findsOneWidget,
      );

      expect(
        find.text('Retry'),
        findsNothing,
        reason: 'bound to the first account, it could only fail again',
      );
    });

    testWidgets('photos gone after a half-done move are no longer ticked', (
      tester,
    ) async {
      // The faces went out, the naming failed: the picking mode stays on,
      // but the photos it held are no longer this person's.
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
          _photo('2', ['20']),
        ],
        people: [anna],
      )..failRenameWith = Exception('offline');
      client.whileDetaching = () => client.photos.removeAt(0);
      await _open(tester, client);
      await _pickFirst(tester);
      expect(find.text('Selected: 1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(find.text('Selected: 1'), findsNothing);
      expect(find.byType(MediaThumbnail), findsOneWidget);
      expect(
        find.byIcon(Icons.person_add_alt),
        findsNothing,
        reason: 'out of the picking mode',
      );
    });

    testWidgets('the answer arrives when the screen was left meanwhile', (
      tester,
    ) async {
      // The faces went out, the naming failed after the person was left.
      // That message is the only word on where the photos now are.
      final client =
          _FacesClient(
              photos: [
                _photo('1', ['10']),
              ],
              people: [anna],
            )
            ..failRenameWith = Exception('offline')
            ..holdRename = Completer<void>();
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Move'));
      await tester.pump();

      // The person goes; the app around it, and its messenger, stay.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_FixedAuth.new),
            clientProvider.overrideWithValue(client),
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

    testWidgets('a split that names no group is not reported as named', (
      tester,
    ) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..createdGroup = null;
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(client.renames, isEmpty);
      expect(find.text('Moved to Max'), findsNothing);
      expect(find.text('Split off as a new person'), findsOneWidget);
    });

    testWidgets('a move that fails before anything moved says so', (
      tester,
    ) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      )..failWith = Exception('offline');
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New person…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Max');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(find.textContaining('Could not move the photos'), findsOneWidget);
      expect(client.renames, isEmpty);
    });

    testWidgets('offers the unnamed, which splits the photos off', (
      tester,
    ) async {
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);
      await _pickFirst(tester);

      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Unlabeled'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Take 1 photo out of Regina? It will show under “Unlabeled”.',
        ),
        findsOneWidget,
      );
      await _confirm(tester);

      expect(client.detaches, [
        ['10'],
      ]);
      expect(client.moves, isEmpty);
    });

    group('typing a name', () {
      const bernd = FaceGroup(id: '11', label: 'Bernd', imageFaceCount: 2);
      const hanna = FaceGroup(id: '12', label: 'Hanna', imageFaceCount: 1);
      const nameless = FaceGroup(id: '13', imageFaceCount: 4);

      Finder inDialog(String text) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(text),
      );

      Future<void> openPicker(WidgetTester tester, _FacesClient client) async {
        await _open(tester, client);
        await _pickFirst(tester);
        await tester.tap(find.byIcon(Icons.person_add_alt));
        await tester.pumpAndSettle();
      }

      testWidgets('keeps only the people whose name holds it, in any case', (
        tester,
      ) async {
        final client = _FacesClient(
          photos: [
            _photo('1', ['10']),
          ],
          people: [anna, bernd, hanna, nameless],
        );
        await openPicker(tester, client);
        expect(inDialog('Bernd'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'AN');
        await tester.pumpAndSettle();

        expect(inDialog('Anna'), findsOneWidget);
        expect(inDialog('Hanna'), findsOneWidget);
        expect(inDialog('Bernd'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Unlabeled'),
          ),
          findsNothing,
          reason: 'the unnamed have no name to match, nor does their entry',
        );

        await tester.tap(find.byIcon(Icons.clear));
        await tester.pumpAndSettle();
        expect(inDialog('Bernd'), findsOneWidget);
      });

      testWidgets('a match is picked like any other', (tester) async {
        final client = _FacesClient(
          photos: [
            _photo('1', ['10']),
          ],
          people: [anna, bernd],
        );
        await openPicker(tester, client);

        await tester.enterText(find.byType(TextField), 'ber');
        await tester.pumpAndSettle();
        await tester.tap(inDialog('Bernd'));
        await tester.pumpAndSettle();
        await _confirm(tester);

        expect(client.moves.single.destination, '11');
        expect(client.moves.single.faces, ['10']);
      });

      testWidgets('says so when nobody matches, and offers the name for a '
          'new person', (tester) async {
        final client = _FacesClient(
          photos: [
            _photo('1', ['10']),
          ],
          people: [anna, bernd],
        );
        await openPicker(tester, client);

        await tester.enterText(find.byType(TextField), ' Max ');
        await tester.pumpAndSettle();
        expect(inDialog('Nobody by that name'), findsOneWidget);
        // One line, with the name in it, so the keyboard leaves room for the
        // people below.
        expect(inDialog('Make a new person and give it a name'), findsNothing);

        await tester.tap(inDialog('New person “Max”…'));
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, 'Max');
        expect(
          find.text('Remove'),
          findsNothing,
          reason: 'a suggestion, not a name to take away',
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        await _confirm(tester);
        expect(client.renames.single, (group: '42', label: 'Max'));
      });

      testWidgets('fetches no further pages of the unnamed', (tester) async {
        // Every named person comes with the first page; the pages after it
        // hold only the unnamed, which a name never matches.
        final client = _FacesClient(
          photos: [
            _photo('1', ['10']),
          ],
          people: [
            anna,
            for (var i = 0; i < 60; i++)
              FaceGroup(id: 'u$i', imageFaceCount: 60 - i),
          ],
        );
        await openPicker(tester, client);
        final before = [...client.pageOffsets];

        await tester.enterText(find.byType(TextField), 'anna');
        await tester.pumpAndSettle();

        expect(inDialog('Anna'), findsOneWidget);
        expect(client.pageOffsets, before);
      });
    });

    testWidgets('merging offers only the people there are', (tester) async {
      // A whole person cannot be merged into nobody.
      final client = _FacesClient(
        photos: [
          _photo('1', ['10']),
        ],
        people: [anna],
      );
      await _open(tester, client);

      await tester.tap(find.byIcon(Icons.merge_type));
      await tester.pumpAndSettle();

      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('New person…'), findsNothing);
    });
  });

  testWidgets('a refused split is reported, not swallowed', (tester) async {
    final client = _FacesClient(
      photos: [
        _photo('1', ['10']),
      ],
      people: [anna],
    )..failWith = const ApiException('Could not reach the server');
    await _open(tester, client);
    await _pickFirst(tester);

    await _split(tester);

    expect(find.textContaining('Could not split them off'), findsOneWidget);
  });
}
