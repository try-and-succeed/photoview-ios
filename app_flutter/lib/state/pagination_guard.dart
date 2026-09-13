import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Discards a paginating request that finishes after its provider moved on.
///
/// `loadMore` awaits a network call and then writes to `state`. If the
/// provider was rebuilt or disposed while that request was in flight — a
/// pull-to-refresh, a server switch, or simply leaving the screen — the write
/// would either resurrect a stale page or touch a disposed provider.
///
/// Capture [generation] before awaiting and check [movedOn] afterwards, before
/// touching any accumulated state.
mixin PaginationGuard {
  int _generation = 0;

  /// Identifies the current build. Changes on every rebuild and on disposal.
  int get generation => _generation;

  /// Call at the start of `build`.
  ///
  /// Both a rebuild and a disposal advance the generation, so a single check
  /// covers them. Registering in `build` is deliberate: Riverpod discards
  /// these callbacks when the provider is recomputed, which is exactly when an
  /// in-flight page becomes stale.
  void beginGeneration(Ref ref) {
    _generation++;
    ref.onDispose(() => _generation++);
  }

  bool movedOn(int captured) => captured != _generation;
}
