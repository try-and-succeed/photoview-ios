import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'search_limit.dart' show settingsStoreProvider;

/// How photos are laid out wherever they are listed.
enum MediaLayout {
  /// Square thumbnails, as many to a row as fit.
  grid,

  /// One row per photo: a small thumbnail and the file name beside it, as
  /// long as it is.
  list;

  static MediaLayout? byName(String? name) {
    for (final layout in values) {
      if (layout.name == name) return layout;
    }
    return null;
  }
}

/// The chosen layout, kept on the device like the other display preferences.
///
/// One choice for every list of photos: switching in the timeline also
/// switches the albums, a person's page and the search results, so the app
/// never shows tiles in one place and names in the next without being asked.
class MediaLayoutNotifier extends AsyncNotifier<MediaLayout> {
  @override
  Future<MediaLayout> build() async =>
      MediaLayout.byName(await ref.read(settingsStoreProvider).mediaLayout()) ??
      MediaLayout.grid;

  /// Switches to [layout] at once and stores it for the next start.
  ///
  /// A choice that cannot be stored still applies until the app is closed;
  /// the failure is not worth a message, as it costs only the default next
  /// time.
  Future<void> choose(MediaLayout layout) async {
    state = AsyncData(layout);
    try {
      await ref.read(settingsStoreProvider).setMediaLayout(layout.name);
    } catch (_) {}
  }
}

final mediaLayoutProvider =
    AsyncNotifierProvider<MediaLayoutNotifier, MediaLayout>(
      MediaLayoutNotifier.new,
    );
