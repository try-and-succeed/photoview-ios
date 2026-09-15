import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/scanner.dart';
import '../widgets/async_states.dart';

/// Opens the scanner on [navigator].
///
/// Takes the navigator rather than a context because one caller is a SnackBar
/// action: by the time it is tapped, the screen that showed it may be gone,
/// and looking a Navigator up from its deactivated context would fail.
void showScanner(NavigatorState navigator) {
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => const ScannerScreen()),
  );
}

/// What the scanner is working on, and a way to stop it.
class ScannerScreen extends ConsumerWidget {
  const ScannerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanner = ref.watch(scannerProvider);
    final notifier = ref.read(scannerProvider.notifier);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scannerTitle),
        actions: [
          if (scanner.jobs.isNotEmpty)
            TextButton(
              onPressed: () => _cancelAll(context, ref),
              child: Text(l10n.scannerStopAll),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: notifier.refresh,
        child: _body(context, scanner, notifier),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ScannerState scanner,
    ScannerNotifier notifier,
  ) {
    final l10n = AppLocalizations.of(context);

    if (scanner.isLoading && scanner.jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = scanner.error;
    if (error != null && scanner.jobs.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          ErrorMessage(message: error, onRetry: notifier.refresh),
        ],
      );
    }

    if (scanner.jobs.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          EmptyMessage(message: l10n.scannerIdle, icon: Icons.radar),
        ],
      );
    }

    // A failed refresh keeps the jobs it had, so the list alone would go on
    // showing a snapshot that may be minutes old with nothing to say so.
    final banner = error == null ? 0 : 1;

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: scanner.jobs.length + banner + 1,
      itemBuilder: (context, index) {
        if (banner == 1 && index == 0) {
          return _StaleBanner(message: error!, onRetry: notifier.refresh);
        }

        final jobIndex = index - banner;
        if (jobIndex == scanner.jobs.length) return const _ScannerNote();

        final job = scanner.jobs[jobIndex];
        final stopping = scanner.stopping.contains(job.albumId);

        return ListTile(
          leading: _statusIcon(context, job.status, stopping),
          title: Text(
            job.albumTitle.isEmpty ? l10n.untitledAlbum : job.albumTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(_statusLabel(l10n, job.status, stopping)),
          trailing: stopping
              ? null
              : IconButton(
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: l10n.scannerStopAlbum,
                  onPressed: () => notifier.cancel(job.albumId),
                ),
        );
      },
    );
  }

  static Widget _statusIcon(
    BuildContext context,
    ScannerJobStatus status,
    bool stopping,
  ) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;

    if (stopping) return Icon(Icons.hourglass_bottom, color: color);

    return switch (status) {
      ScannerJobStatus.running => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      // An unrecognised status still means the scanner is busy with it.
      ScannerJobStatus.queued ||
      ScannerJobStatus.unknown => Icon(Icons.schedule, color: color),
    };
  }

  static String _statusLabel(
    AppLocalizations l10n,
    ScannerJobStatus status,
    bool stopping,
  ) {
    if (stopping) return l10n.scannerStopping;

    return switch (status) {
      ScannerJobStatus.running => l10n.scannerRunning,
      ScannerJobStatus.queued => l10n.scannerQueued,
      ScannerJobStatus.unknown => l10n.scannerBusy,
    };
  }

  Future<void> _cancelAll(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);

    try {
      final cancelled = await ref.read(scannerProvider.notifier).cancelAll();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.scannerStoppedJobs(cancelled))),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// Says that what is below it may be out of date, and offers to try again.
class _StaleBanner extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _StaleBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.scannerRefreshFailed(message),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(l10n.actionRetry)),
        ],
      ),
    );
  }
}

/// Explains the one thing about this screen that is not self-evident.
class _ScannerNote extends StatelessWidget {
  const _ScannerNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Text(
        AppLocalizations.of(context).scannerNote,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
