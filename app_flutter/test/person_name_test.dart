import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/screens/person_screen.dart';
import 'package:photoview/state/auth.dart';

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

/// Records what was sent and answers as the server does — with the label it
/// stored, which is null once a name is removed.
class _NamingClient extends PhotoviewClient {
  _NamingClient() : super(_session);

  final calls = <(String, String?)>[];
  Object? failWith;

  @override
  Future<String?> setFaceGroupLabel(String faceGroupId, String? label) async {
    calls.add((faceGroupId, label));
    final failure = failWith;
    if (failure != null) throw failure;
    return label;
  }

  @override
  Future<List<MediaItem>> personMedia(String faceGroupId) async => const [];
}

Future<void> _openPerson(
  WidgetTester tester,
  _NamingClient client, {
  String? label,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_FixedAuth.new),
        clientProvider.overrideWithValue(client),
      ],
      child: localizedApp(
        home: PersonScreen(
          faceGroup: FaceGroup(id: '7', label: label, imageFaceCount: 3),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a person can be given a name', (tester) async {
    // Naming was only possible in the web interface, though the mutation has
    // always been in the schema.
    final client = _NamingClient();
    await _openPerson(tester, client);

    expect(find.text('Unlabeled'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Regina');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(client.calls, [('7', 'Regina')]);
    expect(find.text('Regina'), findsOneWidget);
  });

  testWidgets('a name is trimmed before it is sent', (tester) async {
    final client = _NamingClient();
    await _openPerson(tester, client);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Regina  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(client.calls, [('7', 'Regina')]);
  });

  testWidgets('clearing the field removes the name rather than storing one', (
    tester,
  ) async {
    // The server takes a null label as "no name"; an empty string would be a
    // person called "".
    final client = _NamingClient();
    await _openPerson(tester, client, label: 'Regina');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(client.calls, [('7', null)]);
    expect(find.text('Unlabeled'), findsOneWidget);
  });

  testWidgets('retrying sends the name already typed, with no second dialog', (
    tester,
  ) async {
    // The retry must repeat the sending, not the asking: the user has typed
    // the name once and then answered a question about a certificate they did
    // not expect. Being sent back to an empty dialog is losing the work.
    //
    // The probe finds nothing to show here — a widget test has no socket —
    // which is the second of the two outcomes that try the action again.
    final client = _NamingClient()
      ..failWith = CertificateNotTrustedException(_session.endpoint);

    await _openPerson(tester, client);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Regina');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(client.calls, [('7', 'Regina')], reason: 'the first attempt failed');
    expect(find.text('Review certificate'), findsOneWidget);

    // The server is reachable again, as it is once the certificate is accepted.
    client.failWith = null;

    await tester.tap(find.text('Review certificate'));
    await tester.pumpAndSettle();

    expect(
      client.calls,
      [('7', 'Regina'), ('7', 'Regina')],
      reason: 'the same name goes out again, with no second dialog',
    );
    expect(find.byType(TextField), findsNothing, reason: 'no dialog reopened');
    expect(find.text('Regina'), findsOneWidget);
  });

  testWidgets('Remove is not offered for a person who has no name', (
    tester,
  ) async {
    await _openPerson(tester, _NamingClient());

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('Remove is offered for a person who has one', (tester) async {
    await _openPerson(tester, _NamingClient(), label: 'Regina');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('Remove clears the name', (tester) async {
    final client = _NamingClient();
    await _openPerson(tester, client, label: 'Regina');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(client.calls, [('7', null)]);
    expect(find.text('Unlabeled'), findsOneWidget);
  });

  testWidgets('backing out of the dialog sends nothing', (tester) async {
    final client = _NamingClient();
    await _openPerson(tester, client, label: 'Regina');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Someone else');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(client.calls, isEmpty);
    expect(find.text('Regina'), findsOneWidget);
  });

  testWidgets('a name the server would not take is reported, not swallowed', (
    tester,
  ) async {
    final client = _NamingClient()
      ..failWith = const ApiException('Could not reach the server');
    await _openPerson(tester, client, label: 'Regina');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Regine');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save the name'), findsOneWidget);
    // The old name stands: nothing was stored.
    expect(find.text('Regina'), findsOneWidget);
  });
}
