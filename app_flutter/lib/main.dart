import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/trusted_cas.dart';
import 'api/trusted_certificates.dart';
import 'screens/app_shell.dart';
import 'screens/welcome_screen.dart';
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

class PhotoviewApp extends StatelessWidget {
  const PhotoviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photoview',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const _Root(),
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
    final auth = ref.watch(authProvider);

    return auth.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const WelcomeScreen(),
      data: (session) => session == null ? const WelcomeScreen() : const AppShell(),
    );
  }
}
