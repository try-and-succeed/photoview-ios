import 'package:flutter/material.dart';
import 'package:photoview/l10n/app_localizations.dart';

/// A MaterialApp with the app's translations, for widget tests.
///
/// English unless [locale] says otherwise, so a test reads the same whatever
/// language the machine running it is set to.
MaterialApp localizedApp({required Widget home, Locale? locale}) => MaterialApp(
  locale: locale ?? const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);
