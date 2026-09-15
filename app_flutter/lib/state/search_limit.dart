import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/settings_store.dart';
import 'auth.dart';
import 'capabilities.dart';

/// Default number of hits per kind when the user has set no limit.
///
/// Matches what the server applies when the arguments are omitted, so the app
/// behaves the same before and after the setting is touched.
const defaultSearchResultLimit = 10;

/// Largest limit that can be stored.
///
/// The server's counter is a 32-bit int: a value above that came back as
/// unlimited from a live instance, which would silently turn "as many as
/// possible" into "all of them". Clamped well below that anyway, because
/// rendering tens of thousands of hits is its own problem.
const maxSearchResultLimit = 10000;

final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(),
);

/// Where the search limit is kept for the current server.
enum SearchLimitSource {
  /// Stored on the server, so it follows the user to other clients.
  server,

  /// Stored on this device, because the server cannot keep it.
  device,
}

/// The search limit, and where it came from.
class SearchLimit {
  /// Null means "no limit set", so the default applies. Zero means unlimited.
  final int? value;
  final SearchLimitSource source;

  const SearchLimit({required this.value, required this.source});

  /// What to send as `limitMedia` / `limitAlbums`.
  ///
  /// Null is passed through as null so the server applies its own default
  /// rather than the app second-guessing it.
  int? get limitArgument => value;

  bool get isUnlimited => value == 0;

  /// How the setting reads in a text field: unset and unlimited are different
  /// things, and only one of them is a number.
  String get asText => value == null ? '' : '$value';
}

/// Reads the limit from wherever this server keeps it.
final searchLimitProvider = FutureProvider<SearchLimit>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) {
    return const SearchLimit(value: null, source: SearchLimitSource.device);
  }

  // Read before any await: watching afterwards would register against a build
  // that may already be gone. This matters here because the server path can
  // fall through to the device path, which means an await now sits between the
  // top of the provider and the store.
  final onServer = ref.watch(
    hasCapabilityProvider(Capability.searchLimitPreference),
  );
  final client = ref.watch(clientProvider);
  final store = ref.watch(settingsStoreProvider);

  if (onServer && client != null) {
    try {
      final preferences = await client.userPreferences();
      return SearchLimit(
        value: preferences.searchResultLimit,
        source: SearchLimitSource.server,
      );
    } on UnsupportedFieldException catch (failure) {
      // The cache said the server could store this and it turns out it cannot
      // — a server that was downgraded, or an answer that was wrong. Record
      // the correction so it heals itself, then carry on to the device store
      // instead of failing: this provider is awaited by the search itself, so
      // throwing here would break searching altogether over a setting.
      await ref.read(capabilityDowngradeProvider)(session.serverId, failure);
    }
  }

  final stored = await store.searchResultLimit(session.serverId);

  return SearchLimit(value: stored, source: SearchLimitSource.device);
});

/// Writes the limit to wherever this server keeps it.
///
/// [limit] is the value the setting should have: a number, 0 for unlimited, or
/// null to clear it. There is no "leave unchanged" — the server's mutation
/// replaces the whole preferences record, so the caller has to say what the
/// record should be.
final setSearchLimitProvider = Provider<Future<void> Function(int?)>((ref) {
  return (limit) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    // Annotated rather than inferred: `clamp` is declared on num, and only a
    // special case in the analyser narrows it to int for int arguments. Saying
    // int? here makes the guarantee explicit and fails loudly if that ever
    // stops holding, instead of silently widening to num.
    final int? clamped = limit?.clamp(0, maxSearchResultLimit);

    final onServer = ref.read(
      hasCapabilityProvider(Capability.searchLimitPreference),
    );

    // Whether this server also keeps the album-tree preference. A separate
    // capability, so it has to be asked separately — but it travels in the
    // same record, and the mutation replaces that record whole.
    var withAlbumTree = ref.read(
      hasCapabilityProvider(Capability.albumTreePreference),
    );
    final client = ref.read(clientProvider);

    // At most two attempts: the second only drops showAlbumTree.
    while (onServer && client != null) {
      try {
        // Read first, then write every field back. The mutation replaces the
        // record, so writing the limit alone would erase the language and the
        // album-tree setting the user picked in the web interface.
        final current = await client.userPreferences(
          withAlbumTree: withAlbumTree,
        );
        await client.changeUserPreferences(
          language: current.language,
          searchResultLimit: clamped,
          showAlbumTree: current.showAlbumTree,
          withAlbumTree: withAlbumTree,
        );
        ref.invalidate(searchLimitProvider);
        return;
      } on UnsupportedFieldException catch (failure) {
        // Same correction as on the read path, so a wrong "supported" corrects
        // itself.
        await ref.read(capabilityDowngradeProvider)(session.serverId, failure);

        // Only the album-tree field was refused: the server still keeps the
        // limit, and the read path goes on reading it from there. Saving to
        // the device instead would report success while the value shown
        // springs back to the server's.
        final ruledOut = failure.ruledOut;
        if (withAlbumTree &&
            ruledOut.contains(Capability.albumTreePreference) &&
            !ruledOut.contains(Capability.searchLimitPreference)) {
          withAlbumTree = false;
          continue;
        }

        // The limit itself cannot be kept on this server: it moves to the
        // device instead.
        break;
      }
    }

    await ref
        .read(settingsStoreProvider)
        .setSearchResultLimit(session.serverId, clamped);
    ref.invalidate(searchLimitProvider);
  };
});

/// Reads what the user typed as a limit.
///
/// Returns null for "clear the setting", which is what an empty field means.
/// Anything that is not a non-negative number is rejected rather than
/// guessed at: the server refuses a negative limit outright, so silently
/// turning -5 into 5 or 0 would store something the user did not ask for.
({int? limit, String? error}) parseSearchLimit(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return (limit: null, error: null);

  final parsed = int.tryParse(trimmed);
  if (parsed == null) return (limit: null, error: 'Enter a whole number.');
  if (parsed < 0) {
    return (limit: null, error: 'A limit cannot be negative. Use 0 for no limit.');
  }
  if (parsed > maxSearchResultLimit) {
    return (limit: null, error: 'At most $maxSearchResultLimit.');
  }

  return (limit: parsed, error: null);
}
