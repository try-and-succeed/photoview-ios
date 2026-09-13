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

  Future<void> refresh() async {
    final generation = this.generation;
    final serverId = ref.read(sessionProvider)?.serverId;

    try {
      final jobs = await ref.guardedRead((c) => c.scannerQueue());
      if (movedOn(generation)) return;

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
      _timer?.cancel();

      if (serverId != null) {
        await ref.read(capabilityDowngradeProvider)(serverId, failure);
      }

      if (movedOn(generation)) return;
      state = state.copyWith(isLoading: false, error: '$failure');
      return;
    } catch (error) {
      if (movedOn(generation)) return;
      state = state.copyWith(isLoading: false, error: '$error');
    }

    _reschedule();
  }

  /// Queues [albumId] and its sub-albums.
  ///
  /// Never retried on failure — see `PhotoviewClient._mutate`. The caller is
  /// told what happened and can ask again deliberately.
  Future<String?> scanAlbum(String albumId) async {
    final message = await ref.guardedRead((c) => c.scanAlbum(albumId));
    await refresh();
    return message;
  }

  /// Asks the server to stop one album's job.
  Future<void> cancel(String albumId) async {
    state = state.copyWith(stopping: {...state.stopping, albumId});

    try {
      final accepted = await ref.guardedRead(
        (c) => c.cancelScanJob(albumId),
      );

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
      state = state.copyWith(
        stopping: {...state.stopping}..remove(albumId),
        error: '$error',
      );
      return;
    }

    await refresh();
  }

  /// Asks the server to stop everything, returning how many jobs it cancelled.
  Future<int> cancelAll() async {
    final ids = state.jobs.map((j) => j.albumId).toSet();
    state = state.copyWith(stopping: {...state.stopping, ...ids});

    try {
      final cancelled = await ref.guardedRead((c) => c.cancelAllScanJobs());
      await refresh();
      return cancelled;
    } catch (error) {
      state = state.copyWith(
        stopping: {...state.stopping}..removeAll(ids),
        error: '$error',
      );
      rethrow;
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
