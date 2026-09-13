import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'capabilities.dart';
import 'secure_storage.dart';

/// Bumped whenever the probe document or the capability set changes.
///
/// The reason to discard a cached answer is that the app now asks a different
/// question — not that its version string moved — so the cache is keyed on the
/// probes rather than on the app version. A release that does not touch
/// capabilities keeps every cached answer, and one that does invalidates them
/// all without needing a dependency to read the version at runtime.
const capabilityProbeRevision = 1;

/// How long a "your server does not have this" answer is trusted.
///
/// Servers get updated, and an app that remembered a missing feature forever
/// would never notice. Seven days keeps the probe off the critical path
/// without making the user wait a release for a server upgrade to show up.
const capabilityMissDuration = Duration(days: 7);

/// Remembers what each server answered, so the probe does not run on every
/// launch.
///
/// Asymmetric on purpose: a feature that is present does not go away on its
/// own, so `supported` never expires — it is instead downgraded the moment a
/// real call proves it wrong, which lets a wrong answer heal itself. A feature
/// that is absent may appear with the next server update, so `unsupported`
/// expires.
class CapabilityStore {
  static const _key = 'server-capabilities';

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;

  CapabilityStore({FlutterSecureStorage? storage, DateTime Function()? now})
    : _storage = storage ?? photoviewSecureStorage,
      _now = now ?? DateTime.now;

  /// What is remembered for [serverId], with expired misses dropped.
  Future<ServerCapabilities> read(String serverId) async {
    final all = await _readAll();
    final entry = all[serverId];
    if (entry is! Map<String, dynamic>) return ServerCapabilities.unknownToAll;

    if (entry['revision'] != capabilityProbeRevision) {
      return ServerCapabilities.unknownToAll;
    }

    final states = <Capability, CapabilityState>{};
    final supported = entry['supported'];
    if (supported is List) {
      for (final name in supported) {
        final capability = _capabilityNamed(name);
        if (capability != null) states[capability] = CapabilityState.supported;
      }
    }

    final unsupported = entry['unsupported'];
    if (unsupported is Map<String, dynamic>) {
      for (final miss in unsupported.entries) {
        final capability = _capabilityNamed(miss.key);
        if (capability == null) continue;

        final seenAt = DateTime.tryParse('${miss.value}');
        if (seenAt == null) continue;
        if (_now().difference(seenAt) >= capabilityMissDuration) continue;

        states[capability] = CapabilityState.unsupported;
      }
    }

    return ServerCapabilities(states);
  }

  /// Stores [capabilities] for [serverId], keeping every other server's entry.
  ///
  /// Nothing is stored for [CapabilityState.unknown]: an unanswered question
  /// is not an answer, and writing it would make the next launch skip the
  /// probe that could finally settle it.
  Future<void> write(String serverId, ServerCapabilities capabilities) async {
    final stamp = _now().toUtc().toIso8601String();

    final supported = <String>[];
    final unsupported = <String, String>{};
    for (final capability in Capability.values) {
      switch (capabilities[capability]) {
        case CapabilityState.supported:
          supported.add(capability.name);
        case CapabilityState.unsupported:
          unsupported[capability.name] = stamp;
        case CapabilityState.unknown:
          break;
      }
    }

    final all = await _readAll();
    all[serverId] = {
      'revision': capabilityProbeRevision,
      'supported': supported,
      'unsupported': unsupported,
    };

    await _storage.write(key: _key, value: jsonEncode(all));
  }

  /// Forgets [serverId], so the next read probes again.
  Future<void> clear(String serverId) async {
    final all = await _readAll();
    if (all.remove(serverId) == null) return;

    if (all.isEmpty) {
      await _storage.delete(key: _key);
      return;
    }

    await _storage.write(key: _key, value: jsonEncode(all));
  }

  Future<Map<String, dynamic>> _readAll() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (_) {
      // An unreadable store only costs a probe, so it degrades to "nothing
      // remembered" rather than failing the caller.
      return {};
    }

    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static Capability? _capabilityNamed(Object? name) {
    for (final capability in Capability.values) {
      if (capability.name == name) return capability;
    }
    return null;
  }
}
