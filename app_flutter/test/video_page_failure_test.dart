import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/media_proxy.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/library.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

final _video = MediaItem(id: '1', type: MediaType.video, title: 'clip.mp4');

/// A proxy that cannot start — a port that will not bind, a session that
/// ended under it, or media the instance does not own.
class _FailingProxy extends MediaProxy {
  @override
  Future<Uri> serve(Session session, String mediaUrl) async {
    throw StateError('no server today');
  }
}

Future<void> _openVideo(WidgetTester tester, MediaProxy proxy) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(_session),
        mediaProxyProvider.overrideWithValue(proxy),
        mediaDetailsProvider.overrideWith(
          (ref, id) async => MediaDetails(
            media: _video,
            title: 'clip.mp4',
            videoWebUrl: '/api/photo/clip.mp4',
          ),
        ),
      ],
      child: localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenGallery(
              context,
              media: [_video],
              initialIndex: 0,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a player that cannot be prepared says so', (tester) async {
    // The failure used to happen before the try around the playing, so it
    // reached nobody: the spinner turned on and nothing was ever said.
    await _openVideo(tester, _FailingProxy());

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not play video'), findsOneWidget);
  });
}
