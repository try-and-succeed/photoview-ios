import 'dart:ui';

/// A language the app is translated into.
class AppLanguage {
  final Locale locale;

  /// The language's name in that language, as a language picker shows it —
  /// someone looking for their own language recognises it regardless of the
  /// language the app is in at the moment.
  final String nativeName;

  const AppLanguage(this.locale, this.nativeName);

  /// How the choice is stored, e.g. `de` or `zh_TW`.
  String get code => locale.toString();
}

/// The languages of the Photoview web interface, in the order a picker lists
/// them. English first: it is also where an unsupported device language
/// lands.
const appLanguages = <AppLanguage>[
  AppLanguage(Locale('en'), 'English'),
  AppLanguage(Locale('da'), 'Dansk'),
  AppLanguage(Locale('de'), 'Deutsch'),
  AppLanguage(Locale('es'), 'Español'),
  AppLanguage(Locale('eu'), 'Euskara'),
  AppLanguage(Locale('fr'), 'Français'),
  AppLanguage(Locale('it'), 'Italiano'),
  AppLanguage(Locale('nl'), 'Nederlands'),
  AppLanguage(Locale('pl'), 'Polski'),
  AppLanguage(Locale('pt'), 'Português'),
  AppLanguage(Locale('sv'), 'Svenska'),
  AppLanguage(Locale('tr'), 'Türkçe'),
  AppLanguage(Locale('ru'), 'Русский'),
  AppLanguage(Locale('uk'), 'Українська'),
  AppLanguage(Locale('ja'), '日本語'),
  AppLanguage(Locale('zh'), '简体中文'),
  AppLanguage(Locale('zh', 'HK'), '繁體中文（香港）'),
  AppLanguage(Locale('zh', 'TW'), '繁體中文（台灣）'),
];

/// The app language for a stored [code], or null for "follow the device" —
/// also when the code names a language the app no longer has.
AppLanguage? appLanguageForCode(String? code) {
  if (code == null) return null;
  for (final language in appLanguages) {
    if (language.code == code) return language;
  }
  return null;
}

/// Picks the app language for the device's preferred [deviceLocales].
///
/// Goes through the device's languages in order and takes the first the app
/// has, so a German speaker whose first choice is unsupported still gets
/// German. Chinese is matched on script as well as region: a device set to
/// Traditional Chinese without a region gets Traditional (Taiwan), not
/// Simplified. With no match at all, English.
Locale resolveAppLocale(List<Locale>? deviceLocales) {
  for (final device in deviceLocales ?? const <Locale>[]) {
    final match = _matchOne(device);
    if (match != null) return match;
  }
  return appLanguages.first.locale;
}

Locale? _matchOne(Locale device) {
  if (device.languageCode == 'zh') {
    final region = device.countryCode;
    if (region == 'HK' || region == 'MO') return const Locale('zh', 'HK');
    if (region == 'TW') return const Locale('zh', 'TW');
    if (device.scriptCode == 'Hant') return const Locale('zh', 'TW');
    return const Locale('zh');
  }

  for (final language in appLanguages) {
    if (language.locale.languageCode == device.languageCode) {
      return language.locale;
    }
  }
  return null;
}
