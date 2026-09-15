import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/widgets/password_field.dart';

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('starts hidden and can be shown and hidden again', (tester) async {
    await tester.pumpWidget(
      _host(PasswordField(controller: TextEditingController(text: 'secret'))),
    );

    expect(_field(tester).obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(_field(tester).obscureText, isFalse);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(_field(tester).obscureText, isTrue);
  });

  testWidgets('keeps the keyboard from learning the password', (tester) async {
    // With the text visible a keyboard would otherwise treat it as a word to
    // remember and suggest elsewhere.
    await tester.pumpWidget(
      _host(PasswordField(controller: TextEditingController(text: 'secret'))),
    );

    for (final reveal in [false, true]) {
      if (reveal) {
        await tester.tap(find.byTooltip('Show password'));
        await tester.pump();
      }
      final field = _field(tester);
      expect(field.enableSuggestions, isFalse, reason: 'revealed: $reveal');
      expect(field.autocorrect, isFalse, reason: 'revealed: $reveal');
    }
  });

  testWidgets('a field built afresh is hidden again', (tester) async {
    // Leaving the sign-in form removes the field; coming back must not show a
    // password that was revealed before.
    final controller = TextEditingController(text: 'secret');

    await tester.pumpWidget(_host(PasswordField(controller: controller)));
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    expect(_field(tester).obscureText, isTrue);
  });
}
