import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/capability_store.dart';
import 'auth.dart';

final capabilityStoreProvider = Provider<CapabilityStore>(
  (ref) => CapabilityStore(),
);

/// What the current server can do.
///
/// Answers from the cache first and only probes for what is still open, so a
/// launch against a known server costs nothing. Never throws: a probe that
/// fails leaves capabilities [CapabilityState.unknown], which renders as the
/// feature being absent — the app has to stay usable against a server that
/// refuses to answer questions about itself.
final serverCapabilitiesProvider = FutureProvider<ServerCapabilities>((
  ref,
) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return ServerCapabilities.unknownToAll;

  // Everything watched is read here, before the first await. Watching after
  // an await is not allowed: by then the provider may already have been
  // rebuilt or disposed, so the dependency would either fail to register or
  // register against a build that no longer exists.
  final store = ref.watch(capabilityStoreProvider);
  final client = ref.watch(clientProvider);
  final serverId = session.serverId;

  final remembered = await store.read(serverId);
  if (remembered.unresolved.isEmpty) return remembered;
  if (client == null) return remembered;

  try {
    final probed = await client.probeCapabilities();
    final merged = remembered.merge(probed);

    try {
      await store.write(serverId, merged);
    } catch (_) {
      // An answer that cannot be cached is still an answer. Letting the write
      // failure reach the outer catch would hide every feature the server
      // actually has, on a device whose secure storage happens to be
      // unwritable.
    }

    return merged;
  } catch (_) {
    // Deliberately swallowed. A probe is the app asking after optional
    // features; failing to get an answer must not break the screen the user
    // is actually on.
    return remembered;
  }
});

/// One capability, for a widget that only cares about its own feature.
///
/// [CapabilityState.unknown] while the probe is in flight, so a tab or button
/// stays hidden rather than appearing and vanishing again.
final capabilityProvider = Provider.family<CapabilityState, Capability>((
  ref,
  capability,
) {
  final capabilities = ref.watch(serverCapabilitiesProvider);

  // A reload keeps the previous value available, and this provider is keyed on
  // the capability rather than on the server — so after switching servers the
  // old server's answers would be handed out until the new probe lands. An
  // answer for the wrong server is worse than no answer: unknown merely hides
  // a feature, while a stale "supported" offers one that is not there.
  if (capabilities.isLoading) return CapabilityState.unknown;

  return capabilities.valueOrNull?[capability] ?? CapabilityState.unknown;
});

/// Whether a feature may be offered at all.
final hasCapabilityProvider = Provider.family<bool, Capability>(
  (ref, capability) =>
      ref.watch(capabilityProvider(capability)) == CapabilityState.supported,
);

/// Records that a real call proved a capability is not there after all, so a
/// stale "supported" corrects itself instead of failing every time.
///
/// Takes the [serverId] the failing request was made against rather than
/// reading the current session: by the time the failure comes back the user
/// may be on another server, and the correction would then be filed against
/// the wrong account — teaching the app something untrue about a server that
/// never said it.
final capabilityDowngradeProvider =
    Provider<Future<void> Function(String, UnsupportedFieldException)>((ref) {
      return (serverId, failure) async {
        final ruledOut = failure.ruledOut;
        if (ruledOut.isEmpty) return;

        final store = ref.read(capabilityStoreProvider);

        var updated = await store.read(serverId);
        for (final capability in ruledOut) {
          updated = updated.downgrade(capability);
        }

        await store.write(serverId, updated);
        ref.invalidate(serverCapabilitiesProvider);
      };
    });

/// Throws away what is remembered for the current server and probes again,
/// behind "Re-check server features" in the settings.
final recheckCapabilitiesProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    await ref.read(capabilityStoreProvider).clear(session.serverId);
    ref.invalidate(serverCapabilitiesProvider);
  };
});
