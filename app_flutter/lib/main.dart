import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'api/trusted_cas.dart';
import 'api/trusted_certificates.dart';
import 'l10n/app_localizations.dart';
import 'l10n/languages.dart';
import 'screens/app_shell.dart';
import 'screens/welcome_screen.dart';
import 'state/app_language.dart';
import 'state/auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Installed before the first request so GraphQL calls and image loading
  // share the same set of user-accepted certificates.
  final pinned = TrustedCertificateStore();
  final authorities = TrustedCaStore();
  await pinned.load();
  await authorities.load();

  HttpOverrides.global = TrustedCertificateHttpOverrides(
    pinned: pinned,
    authorities: authorities,
  );

  runApp(
    ProviderScope(
      overrides: [
        trustedCertificatesProvider.overrideWithValue(pinned),
        trustedCasProvider.overrideWithValue(authorities),
      ],
      child: const PhotoviewApp(),
    ),
  );
}

class PhotoviewApp extends ConsumerWidget {
  /// The first screen. Replaceable so a test can show one screen inside the
  /// real app setup — its languages above all.
  final Widget home;

  const PhotoviewApp({super.key, this.home = const _Root()});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Null until chosen, and while the stored choice loads: the device
    // language applies meanwhile.
    final chosen = ref.watch(appLanguageProvider).valueOrNull;

    return MaterialApp(
      title: 'Photoview',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      locale: chosen?.locale,
      supportedLocales: [for (final language in appLanguages) language.locale],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      // Replaces Flutter's default, which falls back to the first supported
      // language and does not tell Traditional from Simplified Chinese
      // without a region.
      localeListResolutionCallback: (locales, _) => resolveAppLocale(locales),
      builder: (context, child) {
        // DateFormat and NumberFormat without an explicit locale use this;
        // Flutter's localizations have loaded the formats for every
        // supported language by the time anything is built.
        Intl.defaultLocale = Intl.canonicalizedLocale(
          Localizations.localeOf(context).toString(),
        );
        return child!;
      },
      home: home,
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4A90D9),
      brightness: brightness,
    ),
    useMaterial3: true,
  );
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Everything the user has opened — an album, a person, the gallery, a
    // details sheet — lives above this screen in the navigator. Swapping what
    // is underneath therefore changes nothing they can see: a session that
    // ends while an album is open left them looking at that album, with a
    // "not accepted any more" message and a Retry that could only fail again,
    // while the sign-in screen waited out of sight behind it. Seen on the S10
    // with a token deleted on the server.
    //
    // A server switch ends the session too, and closing those screens is right
    // there as well: they belong to the server being left.
    ref.listen(sessionProvider, (before, after) {
      if (before == null || after != null) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    final auth = ref.watch(authProvider);

    return auth.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const WelcomeScreen(),
      data: (session) => session == null ? const WelcomeScreen() : const AppShell(),
    );
  }
}
