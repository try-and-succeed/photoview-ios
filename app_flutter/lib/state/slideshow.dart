import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'search_limit.dart' show settingsStoreProvider;

/// How long a slideshow rests on each picture when nothing was chosen.
///
/// Long enough to take a picture in, short enough that a room full of people
/// does not start talking about the wait.
const defaultSlideshowSeconds = 5;

/// What the setting offers.
///
/// A short list rather than a free number: the useful range is narrow, and a
/// typed value invites the ones that are no use at all — a slideshow that
/// turns every tenth of a second, or once an hour.
const slideshowSecondsChoices = [3, 5, 10, 15, 30, 60];

/// Seconds per picture, as chosen on this device.
///
/// Kept on the device, like the language: it says how this person likes to
/// look at pictures. The server has nowhere to put it in any case.
class SlideshowSecondsNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async =>
      await ref.read(settingsStoreProvider).slideshowSeconds() ??
      defaultSlideshowSeconds;

  /// Takes effect at once and is stored for the next start. A choice that
  /// cannot be stored still applies for this session, and the failure is
  /// rethrown so the screen can say it will not last.
  Future<void> choose(int seconds) async {
    state = AsyncData(seconds);
    await ref.read(settingsStoreProvider).setSlideshowSeconds(seconds);
  }
}

final slideshowSecondsProvider =
    AsyncNotifierProvider<SlideshowSecondsNotifier, int>(
      SlideshowSecondsNotifier.new,
    );
