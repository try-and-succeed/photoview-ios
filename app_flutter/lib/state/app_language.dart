import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/languages.dart';
import 'search_limit.dart' show settingsStoreProvider;

/// The language the user chose for the app, or null to follow the device.
///
/// Kept on the device only. The server has a language preference of its own
/// for the web interface; choosing a language here deliberately leaves it
/// alone.
class AppLanguageNotifier extends AsyncNotifier<AppLanguage?> {
  @override
  Future<AppLanguage?> build() async =>
      appLanguageForCode(await ref.read(settingsStoreProvider).appLanguage());

  /// Switches the app to [language], or back to the device language for null.
  ///
  /// Takes effect at once, and is stored for the next start. A choice that
  /// cannot be stored still applies for this session, and the failure is
  /// rethrown so the screen can say it will not last.
  Future<void> choose(AppLanguage? language) async {
    state = AsyncData(language);
    await ref.read(settingsStoreProvider).setAppLanguage(language?.code);
  }
}

final appLanguageProvider =
    AsyncNotifierProvider<AppLanguageNotifier, AppLanguage?>(
      AppLanguageNotifier.new,
    );
