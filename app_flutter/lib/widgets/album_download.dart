import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/media_files.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/auth.dart';
import '../util/formatting.dart';
import 'download_button.dart';

/// Downloads a whole album as one ZIP of its originals and saves it into a
/// folder the user picks.
///
/// A dialog shows how much has arrived and offers to stop; the server sends
/// no length for the ZIP, so there is no percentage to show. Once complete,
/// the system "save as" dialog takes over.
Future<void> downloadAlbum(
  BuildContext context,
  WidgetRef ref, {
  required String albumId,
  required String albumTitle,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final fileName = albumZipFileName(albumTitle);

  final outcome = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AlbumDownloadDialog(albumId: albumId, fileName: fileName),
  );

  if (outcome is File) {
    try {
      final saved = await ref.read(saveFileProvider)(outcome, fileName);
      if (saved != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.downloadSaved(fileName))),
        );
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.albumSaveFailed(describeError(error, l10n)))),
      );
    } finally {
      await discardDownload(outcome);
    }
    return;
  }

  if (outcome is DownloadCancelledException) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.downloadCancelled)));
    return;
  }

  if (outcome != null) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.albumDownloadFailed(describeError(outcome, l10n)))),
    );
  }
}

/// Runs the download, and closes with the file, or with what went wrong.
class _AlbumDownloadDialog extends ConsumerStatefulWidget {
  final String albumId;
  final String fileName;

  const _AlbumDownloadDialog({required this.albumId, required this.fileName});

  @override
  ConsumerState<_AlbumDownloadDialog> createState() =>
      _AlbumDownloadDialogState();
}

/// How often the byte count on screen is refreshed. Chunks arrive far more
/// often than that on a fast network, and each would be a rebuild.
const _progressRefresh = Duration(milliseconds: 150);

class _AlbumDownloadDialogState extends ConsumerState<_AlbumDownloadDialog> {
  final _cancellation = DownloadCancellation();
  final _sinceRefresh = Stopwatch()..start();
  int _received = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final session = ref.read(sessionProvider);
    Object? outcome;

    if (session == null) {
      outcome = const UnauthorizedException();
    } else {
      try {
        outcome = await ref
            .read(mediaFileFetcherProvider)
            .fetch(
              session,
              albumDownloadPath(widget.albumId),
              fileName: widget.fileName,
              cancellation: _cancellation,
              onProgress: _onProgress,
            );
      } on UnauthorizedException catch (error) {
        await ref.read(authProvider.notifier).sessionExpired(session);
        outcome = error;
      } catch (error) {
        outcome = error;
      }
    }

    if (mounted) {
      Navigator.of(context).pop(outcome);
    } else if (outcome is File) {
      await discardDownload(outcome);
    }
  }

  void _onProgress(int received) {
    _received = received;
    if (!mounted || _sinceRefresh.elapsed < _progressRefresh) return;
    _sinceRefresh.reset();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PopScope(
      // Back stops the download rather than hiding a transfer that keeps
      // going with nothing on screen to stop it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancellation.cancel();
      },
      child: AlertDialog(
        title: Text(l10n.albumDownloadingTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fileName),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              _cancellation.isCancelled
                  ? l10n.downloadStopping
                  : l10n.downloadReceived(formatBytes(_received)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancellation.isCancelled
                ? null
                : () => setState(_cancellation.cancel),
            child: Text(l10n.actionCancel),
          ),
        ],
      ),
    );
  }
}
