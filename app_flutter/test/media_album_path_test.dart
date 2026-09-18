import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/media_details_sheet.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

/// Exactly what the server answered for a photo in Photos/Landscapes.
const _serverJson = '''
{
  "id": "6077",
  "title": "alpine-crest.jpg",
  "album": {
    "id": "2245",
    "title": "Landscapes",
    "path": [
      {"id": "2241", "title": "Photos"},
      {"id": "1", "title": "photos"}
    ]
  }
}
''';

Future<void> _pumpSheet(WidgetTester tester, MediaDetails details) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        mediaDetailsProvider.overrideWith((ref, id) async => details),
      ],
      child: localizedApp(
        home: Scaffold(
          body: MediaDetailsSheet(
            media: [details.media],
            initialIndex: 0,
            showPreview: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the album path reads from the root down to the album', () {
    // The server sends the ancestors nearest-parent first and leaves the album
    // itself out, which is the reverse of how a path is read.
    final details = MediaDetails.fromJson(
      jsonDecode(_serverJson) as Map<String, dynamic>,
    );

    expect(
      details.album!.crumbs.map((a) => a.title),
      ['photos', 'Photos', 'Landscapes'],
    );
  });

  test('a photo whose album the server did not send keeps working', () {
    final details = MediaDetails.fromJson({'id': '1', 'title': 'a.jpg'});

    expect(details.album, isNull);
  });

  testWidgets('the details show where the photo is', (tester) async {
    final details = MediaDetails.fromJson(
      jsonDecode(_serverJson) as Map<String, dynamic>,
    );

    await _pumpSheet(tester, details);

    expect(find.text('photos / Photos / Landscapes'), findsOneWidget);
  });

  testWidgets('no album, no empty line', (tester) async {
    await _pumpSheet(
      tester,
      MediaDetails(
        media: const MediaItem(id: '1', type: MediaType.photo),
        title: 'a.jpg',
      ),
    );

    expect(find.textContaining(' / '), findsNothing);
  });
}
