import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import 'auth.dart';
import 'capabilities.dart';
import 'stale_response_guard.dart';

/// How often the queue is re-read while something is in it.
///
/// There is no subscription for the scanner, so this is polling.
const scannerPollInterval = Duration(seconds: 3);

/// How often it is re-read while the queue is empty.
///
/// Slower, but not stopped: a scan can be started from another device or by
/// the server's own schedule, and a screen that has given up polling would go
/// on claiming the scanner is idle while it is working. The provider is
/// auto-disposed and the poll pauses in the background, so this only runs
/// while someone is actually looking at it.
const scannerIdlePollInterval = Duration(seconds: 10);

/// What the scanner is doing, as far as the app has been told.
class ScannerState {
  final List<ScannerJob> jobs;

  /// Albums the user has asked to stop that are still in the queue.
  ///
  /// The server has no "cancelling" status: a queued job disappears at once,
  /// while a running one keeps going until it finishes the file it is on. This
  /// is the app's own memory of the request, so the row can say "stopping"
  /// instead of looking like the button did nothing.
  final Set<String> stopping;

  final bool isLoading;
  final String? error;

  const ScannerState({
    this.jobs = const [],
    this.stopping = const {},
    this.isLoading = false,
    this.error,
  });

  bool get isIdle => jobs.isEmpty;

  ScannerState copyWith({
    List<ScannerJob>? jobs,
    Set<String>? stopping,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => ScannerState(
    jobs: jobs ?? this.jobs,
    stopping: stopping ?? this.stopping,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class ScannerNotifier extends AutoDisposeNotifier<ScannerState>
    with StaleResponseGuard {
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _foreground = true;

  @override
  ScannerState build() {
    ref.watch(sessionProvider);

    // A rebuild keeps this notifier, so a queue read already under way against
    // the previous server would otherwise hand the new session that server's
    // album names.
    beginGeneration(ref);

    _lifecycle = AppLifecycleListener(
      onStateChange: (lifecycle) {
        _foreground =
            lifecycle == AppLifecycleState.resumed ||
            lifecycle == AppLifecycleState.inactive;

        // Polling a server the user cannot see is pure cost, so it stops when
        // the app goes away and picks up again when it comes back.
        if (_foreground) {
          _reschedule();
        } else {
          _timer?.cancel();
        }
      },
    );

    ref.onDispose(() {
      _timer?.cancel();
      _lifecycle?.dispose();
    });

    Future.microtask(refresh);
    return const ScannerState(isLoading: true);
  }

  /// Numbers each [refresh], so only the latest one may touch the state.
  int _latestRefresh = 0;

  Future<void> refresh() async {
    final generation = this.generation;
    final serverId = ref.read(sessionProvider)?.serverId;

    // The poll timer, pull-to-refresh and the refresh after a stop can all be
    // out at once, and answers need not come back in order. [movedOn] only
    // tells sessions apart; an older read landing last would put back the
    // queue as it was before the stop, and schedule a second poll.
    final request = ++_latestRefresh;
    bool superseded() => movedOn(generation) || request != _latestRefresh;

    try {
      final jobs = await ref.guardedRead((c) => c.scannerQueue());
      if (superseded()) return;

      // Forget a stop request once its album has left the queue, so the label
      // does not outlive the job it belonged to.
      final present = jobs.map((j) => j.albumId).toSet();

      state = state.copyWith(
        jobs: jobs,
        stopping: state.stopping.intersection(present),
        isLoading: false,
        clearError: true,
      );
    } on UnsupportedFieldException catch (failure) {
      // This server does not have the scanner after all. Record it so the
      // entry points disappear, and stop polling: a field that does not exist
      // will not start existing, so repeating the request every few seconds
      // only burns battery.
      //
      // Cancelled, not merely left unscheduled — a poll queued by an earlier
      // successful refresh is still pending and would fire regardless.
      if (!superseded()) _timer?.cancel();

      if (serverId != null) {
        await ref.read(capabilityDowngradeProvider)(serverId, failure);
      }

      if (superseded()) return;
      state = state.copyWith(isLoading: false, error: '$failure');
      return;
    } catch (error) {
      if (superseded()) return;
      state = state.copyWith(isLoading: false, error: '$error');
    }

    _reschedule();
  }

  /// Queues [albumId] and its sub-albums.
  ///
  /// Never retried on failure — see `PhotoviewClient._mutate`. The caller is
  /// told what happened and can ask again deliberately.
  ///
  /// Held alive for the whole call — see [_keptAlive]. The album screen starts
  /// a scan with a bare `ref.read`, which creates no listener, so without it
  /// this provider is torn down while the request is in flight; and
  /// `scanAlbum` has a two-minute timeout, so that is the ordinary case rather
  /// than a race.
  ///
  /// A second request for an album whose scan is still being requested joins
  /// the first instead of sending another. The button stays tappable while the
  /// request is out, and the server runs a repeated request to completion even
  /// though it deduplicates the queue.
  ///
  /// Every mutation below belongs to the session it was started in. A server
  /// switch rebuilds this same notifier, and album ids are only unique per
  /// server: without that, a scan of album 3 on the new server would join the
  /// old server's request and never be sent, and an old answer would be
  /// written into the new server's state.
  Future<String?> scanAlbum(String albumId) {
    final generation = this.generation;
    final key = (generation, albumId);
    final pending = _scansRequested[key];
    if (pending != null) return pending;

    final request = _keptAlive(() async {
      final message = await ref.guardedRead((c) => c.scanAlbum(albumId));
      if (!movedOn(generation)) await refresh();
      return message;
    });

    // Forgotten once answered, whichever way. whenComplete runs only after
    // the entry is stored, even for a request that fails straight away; the
    // derived future is ignored because the caller handles the error.
    _scansRequested[key] = request;
    request.whenComplete(() {
      if (identical(_scansRequested[key], request)) {
        _scansRequested.remove(key);
      }
    }).ignore();

    return request;
  }

  /// Scan requests still waiting for the server, by session and album.
  final Map<(int, String), Future<String?>> _scansRequested = {};

  /// Asks the server to stop one album's job.
  ///
  /// Held alive like [scanAlbum]: the user can close the scanner screen the
  /// moment they press stop.
  Future<void> cancel(String albumId) => _keptAlive(() async {
    final generation = this.generation;
    state = state.copyWith(stopping: {...state.stopping, albumId});

    try {
      final accepted = await ref.guardedRead(
        (c) => c.cancelScanJob(albumId),
      );
      if (movedOn(generation)) return;

      // False means the server had no job under that album id — the usual
      // answer once it has already finished, and the answer for an album whose
      // sub-albums are the queued ones. Leaving the row marked "stopping"
      // would claim a request the server never took.
      if (!accepted) {
        state = state.copyWith(
          stopping: {...state.stopping}..remove(albumId),
        );
      }
    } catch (error) {
      if (movedOn(generation)) return;
      state = state.copyWith(
        stopping: {...state.stopping}..remove(albumId),
        error: '$error',
      );
      return;
    }

    await refresh();
  });

  /// Asks the server to stop everything, returning how many jobs it cancelled.
  ///
  /// Held alive like [scanAlbum].
  Future<int> cancelAll() => _keptAlive(() async {
    final generation = this.generation;
    final ids = state.jobs.map((j) => j.albumId).toSet();
    state = state.copyWith(stopping: {...state.stopping, ...ids});

    try {
      final cancelled = await ref.guardedRead((c) => c.cancelAllScanJobs());
      if (!movedOn(generation)) await refresh();
      return cancelled;
    } catch (error) {
      // Still reported to the caller, who asked; just not into the state of a
      // session that never made the request.
      if (!movedOn(generation)) {
        state = state.copyWith(
          stopping: {...state.stopping}..removeAll(ids),
          error: '$error',
        );
      }
      rethrow;
    }
  });

  /// Runs [action] with this provider held alive until it has finished.
  ///
  /// For every mutation that ends in [refresh]. If the last listener goes away
  /// while the request is out, this auto-disposed provider is torn down and
  /// the `onDispose` that cancels the poll timer runs; the `refresh()` at the
  /// end would then schedule a new timer that nothing will ever cancel —
  /// measured at two extra queue reads in the twenty seconds after a scan,
  /// going on for as long as the app lives.
  Future<T> _keptAlive<T>(Future<T> Function() action) async {
    final link = ref.keepAlive();
    try {
      return await action();
    } finally {
      link.close();
    }
  }

  void _reschedule() {
    _timer?.cancel();

    // Polling a server the user cannot see is the case worth stopping for.
    if (!_foreground) return;

    _timer = Timer(
      state.isIdle ? scannerIdlePollInterval : scannerPollInterval,
      refresh,
    );
  }
}

final scannerProvider =
    AutoDisposeNotifierProvider<ScannerNotifier, ScannerState>(
      ScannerNotifier.new,
    );
