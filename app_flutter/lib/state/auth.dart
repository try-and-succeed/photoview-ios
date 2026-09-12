import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/session.dart';
import '../api/trusted_cas.dart';
import '../api/trusted_certificates.dart';
import '../util/image_cache.dart';

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// Overridden in `main` with the stores the global [HttpOverrides] consults,
/// so the UI and the TLS check agree on what has been accepted.
final trustedCertificatesProvider = Provider<TrustedCertificateStore>(
  (ref) => throw StateError('trustedCertificatesProvider must be overridden'),
);

final trustedCasProvider = Provider<TrustedCaStore>(
  (ref) => throw StateError('trustedCasProvider must be overridden'),
);

/// Servers the user has signed into, most recently used first.
final savedServersProvider = FutureProvider<List<SavedServer>>(
  (ref) => ref.watch(sessionStoreProvider).servers(),
);

/// Set when a stored token stopped working, so the welcome screen can say so
/// and offer that server's details back to the user.
final expiredSessionProvider = StateProvider<Session?>((ref) => null);

/// The signed-in session, reopened from the most recently used server.
class AuthNotifier extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() async {
    final saved = await ref.read(sessionStoreProvider).mostRecent();
    return saved?.session;
  }

  Future<void> login({
    required String instance,
    required String username,
    required String password,
  }) async {
    final session = await PhotoviewClient.login(
      instance: instance,
      username: username,
      password: password,
    );

    await _activate(
      SavedServer(
        endpoint: session.endpoint,
        username: username,
        token: session.token,
        lastUsed: DateTime.now(),
      ),
    );
  }

  /// Reopens a remembered server without asking for anything.
  Future<void> openSaved(SavedServer server) =>
      _activate(server, touchOnly: true);

  /// Returns to the server list, keeping every saved server so one tap gets
  /// back in.
  Future<void> switchServer() async {
    await clearImageCache();
    state = const AsyncData(null);
  }

  /// Drops the current server's saved token, so signing in needs the password
  /// again.
  Future<void> logOut() async {
    final active = state.valueOrNull;
    if (active != null) await _forgetSession(active);

    await clearImageCache();
    state = const AsyncData(null);
  }

  /// Removes one remembered server from the list.
  Future<void> forget(SavedServer server) async {
    await ref.read(sessionStoreProvider).forget(server.id);
    ref.invalidate(savedServersProvider);

    final active = state.valueOrNull;
    final isActive =
        active != null &&
        active.endpoint == server.endpoint &&
        active.username == server.username;

    if (isActive) {
      await clearImageCache();
      state = const AsyncData(null);
    }
  }

  /// The server rejected the stored token. Forget it rather than leave an
  /// entry that fails every time it is tapped, and remember which server it
  /// was so the user can sign back in without retyping the address.
  Future<void> sessionExpired() async {
    final active = state.valueOrNull;
    if (active != null) {
      await _forgetSession(active);
      ref.read(expiredSessionProvider.notifier).state = active;
    }

    await clearImageCache();
    state = const AsyncData(null);
  }

  Future<void> _activate(SavedServer server, {bool touchOnly = false}) async {
    final store = ref.read(sessionStoreProvider);

    final SavedServer remembered;
    if (touchOnly) {
      remembered = await store.touch(server);
    } else {
      await store.remember(server);
      remembered = server;
    }

    ref.invalidate(savedServersProvider);
    ref.read(expiredSessionProvider.notifier).state = null;
    state = AsyncData(remembered.session);
  }

  Future<void> _forgetSession(Session session) async {
    await ref
        .read(sessionStoreProvider)
        .forget('${session.endpoint}|${session.username}');
    ref.invalidate(savedServersProvider);
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, Session?>(
  AuthNotifier.new,
);

final sessionProvider = Provider<Session?>(
  (ref) => ref.watch(authProvider).valueOrNull,
);

/// API client bound to the current session; null while signed out.
final clientProvider = Provider<PhotoviewClient?>((ref) {
  final session = ref.watch(sessionProvider);
  return session == null ? null : PhotoviewClient(session);
});

/// Runs API calls against the current session, signing the user out if the
/// server has stopped accepting our token.
///
/// Riverpod only allows `watch` while a provider is building, so calls made
/// later — from a notifier method or a button tap — must use the `Read`
/// variant. Providers that watch the client during build are rebuilt when the
/// session changes, which is what keeps the read-based calls current.
extension ClientRef on Ref {
  /// Valid only inside a provider body.
  Future<T> guarded<T>(Future<T> Function(PhotoviewClient client) run) =>
      _guard(watch(clientProvider), run);

  /// For calls made after the provider has built.
  Future<T> guardedRead<T>(Future<T> Function(PhotoviewClient client) run) =>
      _guard(read(clientProvider), run);

  Future<T> _guard<T>(
    PhotoviewClient? client,
    Future<T> Function(PhotoviewClient client) run,
  ) async {
    if (client == null) throw const UnauthorizedException();

    try {
      return await run(client);
    } on UnauthorizedException {
      await read(authProvider.notifier).sessionExpired();
      rethrow;
    }
  }
}
