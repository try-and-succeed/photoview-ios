import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photoview/screens/settings_screen.dart';

import 'support/localized_app.dart';

/// The `version:` line of pubspec.yaml, as name and build number.
({String name, String build}) _pubspecVersion() {
  final line = File('pubspec.yaml')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('version:'));
  final match = RegExp(r'^version:\s*(\S+)\+(\d+)\s*$').firstMatch(line);
  if (match == null) fail('pubspec.yaml version is not name+build: $line');
  return (name: match[1]!, build: match[2]!);
}

void main() {
  group('the Info entry', () {
    Future<void> pumpTile(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: localizedApp(home: const Scaffold(body: AboutAppTile())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the version the build reports', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'photoview',
        packageName: 'com.github.photoview.photoview',
        version: '7.8.9',
        buildNumber: '42',
        buildSignature: '',
      );
      await pumpTile(tester);

      expect(find.text('Version 7.8.9 (build 42)'), findsOneWidget);
    });

    testWidgets('opens the About dialog with version and licence', (
      tester,
    ) async {
      PackageInfo.setMockInitialValues(
        appName: 'photoview',
        packageName: 'com.github.photoview.photoview',
        version: '7.8.9',
        buildNumber: '42',
        buildSignature: '',
      );
      await pumpTile(tester);

      await tester.tap(find.byType(AboutAppTile));
      await tester.pumpAndSettle();

      final dialog = find.byType(AboutDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Version 7.8.9 (build 42)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('GNU GPL v3'),
        ),
        findsOneWidget,
      );
    });
  });

  group('versioning', () {
    // Every change raises the version and says what changed. This keeps the
    // two from drifting apart: a raised version without an entry fails here.
    test('the changelog has an entry for the current version', () {
      final version = _pubspecVersion();
      final changelog = File('../CHANGELOG.md').readAsStringSync();

      expect(
        RegExp(
          '^## \\[?${RegExp.escape(version.name)}\\]?[ )]',
          multiLine: true,
        ).hasMatch(changelog),
        isTrue,
        reason: 'CHANGELOG.md needs a "## ${version.name} ..." heading',
      );
    });
  });
}
