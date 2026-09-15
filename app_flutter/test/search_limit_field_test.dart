import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/search_limit.dart';
import 'package:photoview/widgets/search_limit_field.dart';

import 'support/localized_app.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'tok',
  username: 'admin',
);

void main() {
  late List<int?> stored;

  Future<void> pump(WidgetTester tester, Locale locale) async {
    stored = [];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(_session),
          searchLimitProvider.overrideWith(
            (ref) async => const SearchLimit(
              value: 200,
              source: SearchLimitSource.server,
            ),
          ),
          setSearchLimitProvider.overrideWithValue((limit) async {
            stored.add(limit);
          }),
        ],
        child: localizedApp(
          locale: locale,
          home: const Scaffold(body: SearchLimitField()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('refuses and confirms in the app language', (tester) async {
    await pump(tester, const Locale('de'));

    expect(find.text('Grenze für Suchergebnisse'), findsOneWidget);
    expect(
      find.text('Auf dem Server gespeichert, gilt also auch in der Weboberfläche.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '20000');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    // The maximum is written the German way, with a thousands separator.
    expect(find.text('Höchstens 10.000.'), findsOneWidget);
    expect(stored, isEmpty);

    await tester.enterText(find.byType(TextField), '50');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    expect(stored, [50]);
    expect(find.text('Suchergebnisse auf 50 begrenzt.'), findsOneWidget);
  });

  testWidgets('says the same in English', (tester) async {
    await pump(tester, const Locale('en'));

    await tester.enterText(find.byType(TextField), '20000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('At most 10,000.'), findsOneWidget);
  });
}
