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

  final store = ref.watch(capabilityStoreProvider);
  final serverId = session.serverId;

  final remembered = await store.read(serverId);
  if (remembered.unresolved.isEmpty) return remembered;

  final client = ref.watch(clientProvider);
  if (client == null) return remembered;

  try {
    final probed = await client.probeCapabilities();
    final merged = remembered.merge(probed);
    await store.write(serverId, merged);
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
  return capabilities.valueOrNull?[capability] ?? CapabilityState.unknown;
});

/// Whether a feature may be offered at all.
final hasCapabilityProvider = Provider.family<bool, Capability>(
  (ref, capability) =>
      ref.watch(capabilityProvider(capability)) == CapabilityState.supported,
);

/// Records that a real call proved [capability] is not there after all, so a
/// stale "supported" corrects itself instead of failing every time.
final capabilityDowngradeProvider =
    Provider<Future<void> Function(UnsupportedFieldException)>((ref) {
      return (failure) async {
        final session = ref.read(sessionProvider);
        if (session == null) return;

        final ruledOut = failure.ruledOut;
        if (ruledOut.isEmpty) return;

        final store = ref.read(capabilityStoreProvider);
        final serverId = session.serverId;

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
