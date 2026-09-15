import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';
import 'session.dart' show StorageUnavailable;

/// Settings the app keeps on the device, per server account.
///
/// Exists so a preference the server cannot store still works: an instance
/// without `searchResultLimit` would otherwise mean the setting is simply
/// unavailable, which the user experiences as the app being worse against
/// their server rather than as a server that is behind. Kept per account
/// rather than globally, because the same person may want a small limit on a
/// slow instance and none on a fast one.
///
/// Stored in the same secure storage as the sign-ins purely to share the
/// update-safe configuration; none of this is secret.
class SettingsStore {
  static const _key = 'device-settings';

  final FlutterSecureStorage _storage;

  SettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? photoviewSecureStorage;

  /// The locally stored search limit for [serverId], or null if none is set.
  Future<int?> searchResultLimit(String serverId) async {
    final all = await _readAll();
    final entry = all[serverId];
    if (entry is! Map<String, dynamic>) return null;

    final value = entry['searchResultLimit'];
    return value is int ? value : null;
  }

  /// Stores [limit] for [serverId]; null removes it.
  ///
  /// Throws [StorageUnavailable] rather than writing if the existing settings
  /// cannot be read: a write rebuilds the whole record, so treating a failed
  /// read as "nothing stored" would discard every other server's settings.
  ///
  /// Runs after any change already under way. Every account shares one
  /// record, so two changes that each read it and write it back would keep
  /// only the last one's view — and lose the other account's setting.
  Future<void> setSearchResultLimit(String serverId, int? limit) =>
      _serialized(() => _setSearchResultLimit(serverId, limit));

  /// The end of the queue of changes. Static because every instance shares
  /// the same storage record.
  static Future<void> _queue = Future.value();

  /// Runs [action] after every change queued before it. A failing change
  /// still releases the queue; its caller hears about the failure.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _setSearchResultLimit(String serverId, int? limit) async {
    final all = await _readAllForWrite();
    final entry = all[serverId];
    final updated = <String, dynamic>{
      if (entry is Map<String, dynamic>) ...entry,
    };

    if (limit == null) {
      updated.remove('searchResultLimit');
    } else {
      updated['searchResultLimit'] = limit;
    }

    if (updated.isEmpty) {
      all.remove(serverId);
    } else {
      all[serverId] = updated;
    }

    if (all.isEmpty) {
      await _storage.delete(key: _key);
      return;
    }

    await _storage.write(key: _key, value: jsonEncode(all));
  }

  /// For reading only: a failure degrades to "nothing set", which costs no
  /// more than the default limit.
  Future<Map<String, dynamic>> _readAll() async {
    try {
      return await _readAllForWrite();
    } catch (_) {
      return {};
    }
  }

  /// For the write path: reports a read failure instead of hiding it.
  Future<Map<String, dynamic>> _readAllForWrite() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (error) {
      throw StorageUnavailable(error);
    }

    if (raw == null || raw.isEmpty) return {};

    // A record that is not valid JSON counts as empty, exactly like one that
    // decodes to the wrong shape. The refusal above protects settings that
    // might still be read on another attempt; nothing will ever be read out
    // of this, and refusing would make the setting unsavable for good.
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }
}
