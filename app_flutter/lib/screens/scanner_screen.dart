import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/scanner.dart';
import '../widgets/async_states.dart';

void showScanner(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const ScannerScreen()));
}

/// What the scanner is working on, and a way to stop it.
class ScannerScreen extends ConsumerWidget {
  const ScannerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanner = ref.watch(scannerProvider);
    final notifier = ref.read(scannerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner'),
        actions: [
          if (scanner.jobs.isNotEmpty)
            TextButton(
              onPressed: () => _cancelAll(context, ref),
              child: const Text('Stop all'),
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
        children: const [
          SizedBox(height: 120),
          EmptyMessage(
            message: 'The scanner is idle.\n'
                'You only see jobs for albums you own, unless you are an admin.',
            icon: Icons.radar,
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: scanner.jobs.length + 1,
      itemBuilder: (context, index) {
        if (index == scanner.jobs.length) return const _ScannerNote();

        final job = scanner.jobs[index];
        final stopping = scanner.stopping.contains(job.albumId);

        return ListTile(
          leading: _statusIcon(context, job.status, stopping),
          title: Text(
            job.albumTitle.isEmpty ? 'Untitled album' : job.albumTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(_statusLabel(job.status, stopping)),
          trailing: stopping
              ? null
              : IconButton(
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: 'Stop this album',
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

  static String _statusLabel(ScannerJobStatus status, bool stopping) {
    if (stopping) return 'Stopping after the current file';

    return switch (status) {
      ScannerJobStatus.running => 'Scanning',
      ScannerJobStatus.queued => 'Waiting',
      ScannerJobStatus.unknown => 'Busy',
    };
  }

  Future<void> _cancelAll(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final cancelled = await ref.read(scannerProvider.notifier).cancelAll();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            cancelled == 1
                ? 'Stopped 1 job.'
                : 'Stopped $cancelled jobs.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
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
        'Stopping keeps everything already scanned. A running album finishes '
        'the file it is on first, so it may take a moment to disappear.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
