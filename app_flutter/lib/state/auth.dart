import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/client.dart';
import '../api/session.dart';
import '../api/trusted_cas.dart';
import '../api/trusted_certificates.dart';
import '../util/image_cache.dart';
import 'capabilities.dart';

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// Clearing cached thumbnails, behind a provider so it can be replaced.
///
/// Signing out must not depend on a working cache manager — and a test should
/// not need a real one just to exercise the sign-out paths.
final imageCacheCleanerProvider = Provider<Future<void> Function()>(
  (ref) => clearImageCache,
);

/// Holding the screen on, behind a provider for the same reason: a slideshow
/// leaves the device untouched for minutes, and a test should not need the
/// platform channel to check that the slideshow asks for it.
final screenAwakeProvider = Provider<Future<void> Function(bool)>(
  (ref) => (awake) => WakelockPlus.toggle(enable: awake),
);

/// Overridden in `main` with the stores the global [HttpOverrides] consults,
/// so the UI and the TLS check agree on what has been accepted.
final trustedCertificatesProvider = Provider<TrustedCertificateStore>(
  (ref) => throw StateError('trustedCertificatesProvider must be overridden'),
);

final trustedCasProvider = Provider<TrustedCaStore>(
  (ref) => throw StateError('trustedCasProvider must be overridden'),
);

/// Counts the times the user widened what TLS will accept — a certificate
/// accepted, an authority imported.
///
/// Everything fetched through [ClientRef.guarded] watches this, so one decision
/// reaches every screen. Before, each screen kept the failure it had already
/// suffered: accepting the certificate in the album view left Timeline, Places
/// and People showing the same prompt, for a certificate that was by then
/// trusted. Pinned certificates are short-lived — Caddy's internal CA reissues
/// twice a day — so this is the normal course of a working session.
///
/// Narrowing trust deliberately does not bump it: dropping a pin should not
/// send every open screen back to the server to fail.
final tlsTrustGenerationProvider = StateProvider<int>((ref) => 0);

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

    final server = SavedServer(
      endpoint: session.endpoint,
      username: username,
      token: session.token,
      lastUsed: DateTime.now(),
    );

    // A password sign-in is the moment the user is most likely to have just
    // updated their server, so it is the cheapest place to stop trusting what
    // was remembered about it. Reopening a saved server deliberately does not
    // do this — that path exists to be instant.
    //
    // Before activating, not after: publishing the session first lets the
    // capability provider read the old entry and start probing, and that
    // in-flight write would put back what was just cleared.
    //
    // Keyed on the saved server, not on the session the login returned: that
    // session carries no user name, so its id is `endpoint|` and the clear
    // would miss the account's own entry entirely.
    try {
      await ref.read(capabilityStoreProvider).clear(server.id);
    } catch (_) {
      // Only costs a stale capability answer; never worth failing a login.
    }

    await _activate(server);
    ref.invalidate(serverCapabilitiesProvider);
  }

  /// Reopens a remembered server without asking for anything.
  Future<void> openSaved(SavedServer server) =>
      _activate(server, touchOnly: true);

  /// Returns to the server list, keeping every saved server so one tap gets
  /// back in.
  Future<void> switchServer() => _signOut();

  /// Drops the current server's saved token, so signing in needs the password
  /// again.
  ///
  /// The entry itself stays in the list. Removing it is what the "forget"
  /// action on the welcome screen is for; signing out and finding the server
  /// gone — or, with only one server saved, finding a blank sign-in form —
  /// was the complaint this fixes.
  Future<void> logOut() async {
    final active = state.valueOrNull;
    if (active != null) await _dropToken(active);

    await _signOut();
  }

  /// Removes one remembered server from the list.
  Future<void> forget(SavedServer server) async {
    await ref.read(sessionStoreProvider).forget(server.id);
    ref.invalidate(savedServersProvider);

    if (_isActive(server.endpoint, server.username)) await _signOut();
  }

  /// The server rejected the token used by [failed]. Drop that token rather
  /// than leave an entry that fails every time it is tapped.
  ///
  /// The entry stays, now asking for a password — which is exactly what an
  /// expired token means. [failed] is the session whose request actually
  /// failed, which is not necessarily the active one: a late response from a
  /// server the user has since switched away from must not sign them out of
  /// the server they are now looking at.
  Future<void> sessionExpired(Session failed) async {
    // Only the token that actually failed. A request can be answered after the
    // user has signed in again on the same server, and that account is the
    // same account: without this, a 401 from the sign-in they replaced drops
    // the token of the one they are using and signs them out of it.
    await _dropToken(failed, onlyIfCurrent: true);

    if (!_isActive(failed.endpoint, failed.username)) return;
    if (state.valueOrNull?.token != failed.token) return;

    ref.read(expiredSessionProvider.notifier).state = failed;
    await _signOut();
  }

  bool _isActive(Uri endpoint, String username) {
    final active = state.valueOrNull;
    return active != null &&
        active.endpoint == endpoint &&
        active.username == username;
  }

  /// Clears the session, whatever else fails.
  ///
  /// Dropping the cached images is housekeeping, not part of signing out — if
  /// it throws, the user must still end up signed out rather than stuck with a
  /// session the caller believes is gone.
  Future<void> _signOut() async {
    try {
      await ref.read(imageCacheCleanerProvider)();
    } catch (_) {
      // Stale thumbnails are preferable to a sign-out that did not happen.
    } finally {
      state = const AsyncData(null);
    }
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

    final session = remembered.session;
    if (session == null) {
      // Only reachable by asking to open an entry that has no token, which the
      // welcome screen sends to the sign-in form instead. Loud, because the
      // quiet version of this is `AsyncData(null)` — a sign-out that looks
      // exactly like a successful sign-in that did nothing.
      throw StateError('Cannot open ${remembered.label} without a token');
    }

    ref.invalidate(savedServersProvider);
    ref.read(expiredSessionProvider.notifier).state = null;
    state = AsyncData(session);
  }

  /// Drops the stored token of [session]'s account.
  ///
  /// [onlyIfCurrent] restricts that to the token [session] itself carried, for
  /// callers reacting to something that happened to one particular sign-in
  /// rather than to what the user is doing now.
  Future<void> _dropToken(Session session, {bool onlyIfCurrent = false}) async {
    await ref
        .read(sessionStoreProvider)
        .dropToken(
          session.serverId,
          expected: onlyIfCurrent ? session.token : null,
        );
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
  Future<T> guarded<T>(Future<T> Function(PhotoviewClient client) run) {
    // Accepting a certificate on one screen has to unblock the others, which
    // are sitting on a failure that no longer applies.
    watch(tlsTrustGenerationProvider);
    return _guard(watch(clientProvider), run);
  }

  /// For calls made after the provider has built.
  Future<T> guardedRead<T>(Future<T> Function(PhotoviewClient client) run) =>
      _guard(read(clientProvider), run);

  /// The signed-in client, for an action run from a button rather than from a
  /// provider build.
  ///
  /// Throws when there is no session: a screen that can be tapped without one
  /// should not have been on screen.
  PhotoviewClient get requireClient {
    final client = read(clientProvider);
    if (client == null) throw const UnauthorizedException();
    return client;
  }

  Future<T> _guard<T>(
    PhotoviewClient? client,
    Future<T> Function(PhotoviewClient client) run,
  ) async {
    if (client == null) throw const UnauthorizedException();

    try {
      return await run(client);
    } on UnauthorizedException {
      // Hand over the session that actually failed: by the time a slow request
      // errors, the user may already be on a different server.
      await read(authProvider.notifier).sessionExpired(client.session);
      rethrow;
    }
  }
}
