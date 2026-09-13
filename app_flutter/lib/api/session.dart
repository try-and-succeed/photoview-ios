import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// Credentials for a signed-in Photoview instance.
///
/// [endpoint] is the resolved GraphQL endpoint (e.g. `https://host/api/graphql`).
/// Media URLs returned by the server are relative to it, and the auth token
/// travels as a cookie on both GraphQL calls and every image/video request.
class Session {
  final Uri endpoint;
  final String token;
  final String username;

  const Session({
    required this.endpoint,
    required this.token,
    this.username = '',
  });

  Map<String, String> get headers => {'Cookie': 'auth-token=$token'};

  /// Resolves a server-relative media path against the instance.
  Uri resolve(String url) => endpoint.resolve(url);

  /// Cache key for a media URL, scoped to who is signed in.
  ///
  /// The image cache is keyed by URL alone unless told otherwise, and the auth
  /// cookie does not enter that key — so two accounts on the same instance
  /// would read each other's cached renditions, and clearing the cache on sign
  /// out does not help against a request that is still in flight and lands
  /// afterwards. The token deliberately stays out of the key: it changes on
  /// every sign-in, which would discard the whole cache, and cache keys end up
  /// in file names on disk.
  /// The resolved URL already carries scheme, host and port, so the user name
  /// is all that has to be added to it.
  String cacheKeyFor(String url) => '$username|${resolve(url)}';

  /// Identity of this account on this server, matching [SavedServer.id].
  ///
  /// Anything remembered per server — the saved sign-in, what the server can
  /// do — is filed under this, so two users on one instance and one user on
  /// two instances all stay separate. Defined once because a second spelling
  /// of it would silently look up a different entry.
  String get serverId => '$endpoint|$username';

  /// The address the user originally typed, recovered from the resolved
  /// endpoint by dropping the `graphql` segment and an `api` prefix.
  ///
  /// Feeding the raw endpoint back into a sign-in form would append a second
  /// `graphql` segment, so anything user-facing goes through here.
  Uri get instanceUrl =>
      endpoint.replace(pathSegments: _instanceSegments, query: null, fragment: null);

  /// Public share link for a token, e.g. `https://host/share/rMHkKhmX`.
  Uri shareUrl(String shareToken) => endpoint.replace(
    pathSegments: [..._instanceSegments, 'share', shareToken],
    query: null,
    fragment: null,
  );

  List<String> get _instanceSegments {
    final segments = List<String>.from(endpoint.pathSegments)
      ..removeWhere((s) => s.isEmpty);

    if (segments.isNotEmpty && segments.last == 'graphql') segments.removeLast();
    if (segments.isNotEmpty && segments.last == 'api') segments.removeLast();

    return segments;
  }
}

/// The secure store could not be read, as opposed to being empty.
///
/// The difference matters: treating an unreadable store as empty and then
/// writing to it would replace every saved sign-in with whatever the caller
/// happened to be adding.
class StorageUnavailable implements Exception {
  final Object? cause;
  const StorageUnavailable(this.cause);

  @override
  String toString() => 'Secure storage is unavailable: $cause';
}

/// A server the user has signed into before, kept so it can be reopened with
/// a tap. Only the auth token is stored — never the password.
class SavedServer {
  final Uri endpoint;
  final String username;
  final String token;
  final DateTime lastUsed;

  const SavedServer({
    required this.endpoint,
    required this.username,
    required this.token,
    required this.lastUsed,
  });

  /// Identity of the account on the server, so the same user on two instances
  /// (or two users on one) stay separate entries.
  String get id => session.serverId;

  Session get session =>
      Session(endpoint: endpoint, token: token, username: username);

  /// Host and port, which is what distinguishes instances in the list.
  String get label =>
      endpoint.hasPort ? '${endpoint.host}:${endpoint.port}' : endpoint.host;

  SavedServer withToken(String newToken) => SavedServer(
    endpoint: endpoint,
    username: username,
    token: newToken,
    lastUsed: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint.toString(),
    'username': username,
    'token': token,
    'lastUsed': lastUsed.toIso8601String(),
  };

  static SavedServer? fromJson(Map<String, dynamic> json) {
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    final token = json['token'] as String?;
    if (endpoint == null || !endpoint.hasScheme || token == null) return null;

    return SavedServer(
      endpoint: endpoint,
      username: json['username'] as String? ?? '',
      token: token,
      lastUsed:
          DateTime.tryParse(json['lastUsed'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class SessionStore {
  static const _serversKey = 'saved-servers';

  // Single-session keys from before multiple servers were remembered; read
  // once on first load so an existing sign-in survives the upgrade.
  static const _legacyTokenKey = 'access-token';
  static const _legacyInstanceKey = 'server-instance';

  final FlutterSecureStorage _storage;

  SessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? photoviewSecureStorage;

  /// Saved servers, most recently used first.
  ///
  /// Always a modifiable list: callers add to and remove from it. An
  /// unreadable store reads as empty here so the app falls back to the sign-in
  /// screen; write paths use [_serversForWrite] instead, which refuses to
  /// proceed on the same condition.
  Future<List<SavedServer>> servers() async {
    try {
      return await _serversForWrite();
    } on StorageUnavailable {
      return [];
    }
  }

  /// Like [servers], but propagates a read failure.
  ///
  /// Rebuilding the stored list from a read that failed would persist a
  /// truncated list and silently drop every other saved sign-in, so callers
  /// that write must let this throw.
  Future<List<SavedServer>> _serversForWrite() async {
    final raw = await _read(_serversKey);

    if (raw == null || raw.isEmpty) {
      return [?await _migrateLegacySession()];
    }

    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return [];
    }

    final servers = decoded
        .whereType<Map<String, dynamic>>()
        .map(SavedServer.fromJson)
        .whereType<SavedServer>()
        .toList();

    servers.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return servers;
  }

  /// The server to reopen on launch.
  Future<SavedServer?> mostRecent() async {
    final saved = await servers();
    return saved.isEmpty ? null : saved.first;
  }

  /// Adds the server, or replaces the entry for the same account, and marks it
  /// as the most recently used.
  Future<void> remember(SavedServer server) async {
    final saved = await _serversForWrite();
    saved.removeWhere((s) => s.id == server.id);
    saved.insert(0, server);

    await _write(saved);
  }

  /// Moves an existing entry to the front without changing its token.
  Future<SavedServer> touch(SavedServer server) async {
    final refreshed = server.withToken(server.token);
    await remember(refreshed);
    return refreshed;
  }

  Future<void> forget(String id) async {
    final saved = await _serversForWrite();
    saved.removeWhere((s) => s.id == id);
    await _write(saved);
  }

  Future<void> forgetAll() async {
    await _storage.delete(key: _serversKey);
  }

  Future<void> _write(List<SavedServer> servers) async {
    if (servers.isEmpty) {
      await _storage.delete(key: _serversKey);
      return;
    }

    await _storage.write(
      key: _serversKey,
      value: jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  /// Reads a key, retrying once, and throws [StorageUnavailable] if both
  /// attempts fail.
  ///
  /// The Android Keystore can be briefly unavailable — shortly after boot, for
  /// instance — and a failed read must not be mistaken for a missing value.
  /// Nothing is written on failure, so the stored data stays recoverable on a
  /// later launch.
  Future<String?> _read(String key) async {
    Object? lastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _storage.read(key: key);
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }

    throw StorageUnavailable(lastError);
  }

  Future<SavedServer?> _migrateLegacySession() async {
    final token = await _read(_legacyTokenKey);
    final instance = await _read(_legacyInstanceKey);
    if (token == null || instance == null) return null;

    final endpoint = Uri.tryParse(instance);
    if (endpoint == null || !endpoint.hasScheme) return null;

    // The username was not stored before; it is only shown in the list, and
    // filled in the next time the user signs in on this server.
    final migrated = SavedServer(
      endpoint: endpoint,
      username: '',
      token: token,
      lastUsed: DateTime.now(),
    );

    await _write([migrated]);
    await _storage.delete(key: _legacyTokenKey);
    await _storage.delete(key: _legacyInstanceKey);

    return migrated;
  }
}
