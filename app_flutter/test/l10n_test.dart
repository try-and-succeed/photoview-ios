import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/session.dart';
import 'package:photoview/api/settings_store.dart';
import 'package:photoview/api/trusted_cas.dart';
import 'package:photoview/api/trusted_certificates.dart';
import 'package:photoview/l10n/app_localizations.dart';
import 'package:photoview/l10n/languages.dart';
import 'package:photoview/main.dart';
import 'package:photoview/screens/settings_screen.dart';
import 'package:photoview/state/auth.dart';
import 'package:photoview/state/search_limit.dart';

/// Every ARB file, by locale, as read from lib/l10n.
Map<String, Map<String, dynamic>> _arbFiles() {
  final files = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.arb'));

  return {
    for (final file in files)
      RegExp(r'app_(.+)\.arb$').firstMatch(file.path)!.group(1)!:
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  };
}

Iterable<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@'));

Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)').allMatches(message).map((m) => m.group(1)!).toSet();

void main() {
  group('translations', () {
    final arbs = _arbFiles();
    final english = arbs['en']!;

    test('there is a file for each of the 18 languages, and no other', () {
      expect(
        arbs.keys.toSet(),
        {for (final language in appLanguages) language.code},
      );
    });

    test('every language has every message, and nothing extra', () {
      // A missing message would silently show English; an extra one is a
      // leftover of a message that no longer exists.
      for (final entry in arbs.entries) {
        expect(
          _messageKeys(entry.value).toSet(),
          _messageKeys(english).toSet(),
          reason: 'app_${entry.key}.arb',
        );
      }
    });

    test('no translation is empty or drops a placeholder', () {
      for (final entry in arbs.entries) {
        for (final key in _messageKeys(english)) {
          final message = entry.value[key];
          expect(message, isA<String>(), reason: '${entry.key}: $key');
          expect((message as String).trim(), isNotEmpty, reason: '${entry.key}: $key');
          expect(
            _placeholders(message),
            containsAll(_placeholders(english[key] as String)),
            reason: '${entry.key}: $key',
          );
        }
      }
    });

    test('every English message says what it is for', () {
      for (final key in _messageKeys(english)) {
        final meta = english['@$key'];
        expect(meta, isA<Map<String, dynamic>>(), reason: key);
        expect((meta as Map)['description'], isNotEmpty, reason: key);
      }
    });
  });

  group('appLanguages', () {
    test('matches the languages the translations were generated for', () {
      expect(
        {for (final language in appLanguages) language.locale},
        AppLocalizations.supportedLocales.toSet(),
      );
    });

    test('lists English first, the fallback for an unsupported device', () {
      expect(appLanguages.first.locale, const Locale('en'));
    });

    test('a stored code finds its language; an unknown one follows the device', () {
      expect(appLanguageForCode('de')?.nativeName, 'Deutsch');
      expect(appLanguageForCode('zh_TW')?.locale, const Locale('zh', 'TW'));
      expect(appLanguageForCode('xx'), isNull);
      expect(appLanguageForCode(null), isNull);
    });
  });

  group('resolveAppLocale', () {
    test('takes the device language when the app has it', () {
      expect(resolveAppLocale([const Locale('de', 'DE')]), const Locale('de'));
    });

    test('falls back to English, not to the first language in the list', () {
      // Flutter's default would pick the first supported locale.
      expect(resolveAppLocale([const Locale('ko', 'KR')]), const Locale('en'));
      expect(resolveAppLocale(null), const Locale('en'));
    });

    test('goes down the device preferences before giving up', () {
      expect(
        resolveAppLocale([const Locale('ko'), const Locale('fr', 'CA')]),
        const Locale('fr'),
      );
    });

    test('tells Traditional from Simplified Chinese', () {
      expect(resolveAppLocale([const Locale('zh', 'CN')]), const Locale('zh'));
      expect(resolveAppLocale([const Locale('zh', 'TW')]), const Locale('zh', 'TW'));
      expect(resolveAppLocale([const Locale('zh', 'HK')]), const Locale('zh', 'HK'));
      expect(
        resolveAppLocale([const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')]),
        const Locale('zh', 'TW'),
        reason: 'Traditional without a region is not Simplified',
      );
    });
  });

  group('the language setting', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('is stored on the device and can go back to the device language', () async {
      final store = SettingsStore();
      expect(await store.appLanguage(), isNull);

      await store.setAppLanguage('de');
      expect(await SettingsStore().appLanguage(), 'de');

      await store.setAppLanguage(null);
      expect(await SettingsStore().appLanguage(), isNull);
    });

    testWidgets('a language that cannot be stored applies and says so', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(null),
            settingsStoreProvider.overrideWithValue(_UnwritableSettings()),
            trustedCasProvider.overrideWithValue(TrustedCaStore()),
            trustedCertificatesProvider.overrideWithValue(TrustedCertificateStore()),
          ],
          child: const PhotoviewApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deutsch'));
      await tester.pumpAndSettle();

      expect(find.text('Sprache'), findsOneWidget, reason: 'in use regardless');
      expect(
        find.textContaining('Die Sprache konnte nicht gespeichert werden'),
        findsOneWidget,
      );
    });

    testWidgets('choosing a language switches the app at once and is kept', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(null),
            trustedCasProvider.overrideWithValue(TrustedCaStore()),
            trustedCertificatesProvider.overrideWithValue(TrustedCertificateStore()),
          ],
          child: const PhotoviewApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Tests run with an English device.
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('System default'), findsOneWidget);

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deutsch'));
      await tester.pumpAndSettle();

      expect(find.text('Sprache'), findsOneWidget);
      expect(find.text('Deutsch'), findsOneWidget, reason: 'shown as the choice');
      expect(find.text('Einstellungen'), findsOneWidget);
      expect(find.text('Server wechseln'), findsOneWidget);
      expect(await SettingsStore().appLanguage(), 'de');

      // Back to the device language.
      await tester.tap(find.text('Sprache'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Systemsprache'));
      await tester.pumpAndSettle();

      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(await SettingsStore().appLanguage(), isNull);
    });
  });
}

/// A settings store whose writes fail, as they do when secure storage is
/// unavailable.
class _UnwritableSettings extends SettingsStore {
  @override
  Future<void> setAppLanguage(String? code) async =>
      throw const StorageUnavailable('locked');
}
