import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/people_screen.dart';
import 'package:photoview/state/auth.dart';
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

/// Unnamed people, most photos first, in pages of whatever is asked for.
///
/// [hold] keeps the next answers back until it is completed, so a test can
/// look at the screen while the people are being fetched again.
class _PeopleClient extends PhotoviewClient {
  _PeopleClient() : super(_session);

  Completer<void>? hold;

  @override
  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
    bool fewestFirst = false,
    bool withStatus = false,
  }) async {
    await hold?.future;

    return [
      for (var i = offset; i < offset + limit && i < 300; i++)
        FaceGroup(id: '$i', imageFaceCount: 300 - i),
    ];
  }
}

void main() {
  testWidgets('the list stays where it was while it is fetched again', (
    tester,
  ) async {
    // Found on the device: scrolled far down, a photo moved, back on the
    // list — and at the top of it again, with all the scrolling to redo.
    final client = _PeopleClient();
    late WidgetRef ref;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
          clientProvider.overrideWithValue(client),
        ],
        child: localizedApp(
          home: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const PeopleScreen();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Far enough down that more pages have come in.
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
    }
    final loaded = ref.read(faceGroupsProvider).value!.groups.length;
    expect(loaded, greaterThan(40), reason: 'scrolled past the first page');

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final offset = scrollable.position.pixels;
    expect(offset, greaterThan(2000));

    client.hold = Completer<void>();
    ref.invalidate(faceGroupsProvider);
    await tester.pump();

    expect(
      find.byType(FaceSliverGrid),
      findsOneWidget,
      reason: 'the grid stays while the people are fetched again',
    );
    expect(scrollable.position.pixels, offset);

    client.hold!.complete();
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, offset);
    expect(ref.read(faceGroupsProvider).value!.groups.length, loaded);
  });
}
