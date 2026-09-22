import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/media_files.dart';
import '../api/models.dart';
import '../api/session.dart';
import '../l10n/app_localizations.dart';
import '../state/auth.dart';
import '../state/library.dart';
import 'download_button.dart';

/// What came of fetching the files for a share.
class _Fetched {
  final List<File> files = [];

  /// How many could not be fetched. Named rather than silently dropped: a
  /// share that quietly sends nine of ten photos is worse than one that says
  /// so.
  int failed = 0;
}

/// Downloads the chosen media and hands the files to the system share sheet.
///
/// One at a time, with a count on screen and a way out: an original is
/// megabytes, and a selection is however many the user ticked. Files stay in
/// the temporary directory, as the single-photo share leaves them — the
/// receiving app may still be reading them, and the system clears that
/// directory itself.
Future<void> shareSelectedMedia(
  BuildContext context,
  WidgetRef ref,
  List<MediaItem> items,
) async {
  final session = ref.read(sessionProvider);
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);

  if (session == null || items.isEmpty) return;

  final cancellation = DownloadCancellation();
  final progress = ValueNotifier<int>(0);

  // The dialog owns nothing: it shows the count and can cancel, and the work
  // below carries on if it is dismissed some other way.
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ShareProgressDialog(
        total: items.length,
        done: progress,
        onCancel: cancellation.cancel,
      ),
    ),
  );

  final navigator = Navigator.of(context);
  final fetched = await _fetchAll(
    ref,
    session,
    items,
    cancellation: cancellation,
    onDone: (count) => progress.value = count,
  );

  if (navigator.canPop()) navigator.pop();
  progress.dispose();

  if (cancellation.isCancelled) {
    for (final file in fetched.files) {
      await discardDownload(file);
    }
    return;
  }

  if (fetched.files.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.shareNothingFetched)));
    return;
  }

  if (fetched.failed > 0) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.shareSomeFailed(fetched.failed))),
    );
  }

  await ref.read(shareFilesProvider)(fetched.files);
}

Future<_Fetched> _fetchAll(
  WidgetRef ref,
  Session session,
  List<MediaItem> items, {
  required DownloadCancellation cancellation,
  required void Function(int done) onDone,
}) async {
  final fetcher = ref.read(mediaFileFetcherProvider);
  final result = _Fetched();

  for (final item in items) {
    if (cancellation.isCancelled) break;

    try {
      // The details query is what carries the file URLs; the grid only ever
      // knew the thumbnails.
      final details = await ref.read(mediaDetailsProvider(item.id).future);
      final download = _originalOf(details);
      if (download == null) {
        result.failed++;
        continue;
      }

      result.files.add(
        await fetcher.fetch(
          session,
          download.url,
          fileName: downloadFileName(details.title, download),
          cancellation: cancellation,
        ),
      );
    } on DownloadCancelledException {
      break;
    } on UnauthorizedException {
      // Ends the run: every later file would fail the same way, and the
      // session has to be reported once.
      await ref.read(authProvider.notifier).sessionExpired(session);
      break;
    } catch (_) {
      // One photo that could not be fetched is counted, not fatal: the rest
      // of the selection is still worth sending.
      result.failed++;
    } finally {
      onDone(result.files.length + result.failed);
    }
  }

  return result;
}

/// The full-size file, or the largest the server offers for this medium.
///
/// "Original" is what sharing a photo means; a video has only that one entry
/// anyway, and a server that names its renditions differently still gets the
/// first of them rather than nothing.
MediaDownload? _originalOf(MediaDetails details) {
  final downloads = details.downloads;
  if (downloads.isEmpty) return null;

  for (final download in downloads) {
    if (download.title == 'Original') return download;
  }
  return downloads.first;
}

class _ShareProgressDialog extends StatelessWidget {
  final int total;
  final ValueListenable<int> done;
  final VoidCallback onCancel;

  const _ShareProgressDialog({
    required this.total,
    required this.done,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      content: ValueListenableBuilder<int>(
        valueListenable: done,
        builder: (context, value, _) => Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(l10n.shareFetching(value, total))),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            onCancel();
            Navigator.of(context).pop();
          },
          child: Text(l10n.actionCancel),
        ),
      ],
    );
  }
}
