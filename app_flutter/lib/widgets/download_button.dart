import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../api/client.dart';
import '../api/media_files.dart';
import '../api/models.dart';
import '../state/auth.dart';
import '../util/formatting.dart';

/// Fetches files for saving and sharing, behind a provider so a test can
/// serve them without a server.
final mediaFileFetcherProvider = Provider<MediaFileFetcher>(
  (ref) => MediaFileFetcher(),
);

/// Opens the system "save as" dialog for [file], suggesting [fileName].
/// Returns where it was saved, or null when the user cancelled.
typedef SaveFile = Future<String?> Function(File file, String fileName);

/// Hands [file] to the system share sheet.
typedef ShareFile = Future<void> Function(File file);

/// Behind providers for the same reason as the fetcher: both end in a
/// platform dialog a widget test cannot show.
final saveFileProvider = Provider<SaveFile>(
  (ref) => (file, fileName) => FlutterFileDialog.saveFile(
    params: SaveFileDialogParams(sourceFilePath: file.path, fileName: fileName),
  ),
);

final shareFileProvider = Provider<ShareFile>(
  (ref) => (file) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  },
);

/// One rendition of a photo, with two separate actions: tap to save it into a
/// folder of the user's choice, or the share button to send it to another
/// app. Downloading used to open the share sheet directly, so there was no
/// way to simply keep the file.
class DownloadButton extends ConsumerStatefulWidget {
  final MediaDownload download;

  /// The photo's title, which is its file name in the library.
  final String mediaTitle;

  const DownloadButton({
    super.key,
    required this.download,
    required this.mediaTitle,
  });

  @override
  ConsumerState<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends ConsumerState<DownloadButton> {
  bool _busy = false;

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fetches the file, then runs [use] on it. One action at a time per row.
  Future<void> _withFile(
    String failure,
    Future<void> Function(File file, String fileName) use,
  ) async {
    final session = ref.read(sessionProvider);
    if (session == null || _busy) return;

    setState(() => _busy = true);
    final fileName = downloadFileName(widget.mediaTitle, widget.download);

    try {
      final file = await ref
          .read(mediaFileFetcherProvider)
          .fetch(session, widget.download.url, fileName: fileName);
      if (!mounted) return;
      await use(file, fileName);
    } on UnauthorizedException {
      // This path bypasses the GraphQL client, so it reports an expired
      // session itself — the same way, so it looks the same wherever it
      // surfaces.
      await ref.read(authProvider.notifier).sessionExpired(session);
      _say('$failure: ${const UnauthorizedException()}');
    } catch (error) {
      _say('$failure: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _withFile('Download failed', (file, fileName) async {
    try {
      final saved = await ref.read(saveFileProvider)(file, fileName);
      if (saved != null) _say('Saved $fileName');
    } finally {
      // The copy the dialog made is the one that matters; the cached file
      // would only use up space.
      if (file.existsSync()) await file.delete();
    }
  });

  // The shared file is left in the temporary directory: the receiving app may
  // still be reading it after the share sheet has closed, and the system
  // clears that directory on its own.
  Future<void> _share() => _withFile(
    'Sharing failed',
    (file, _) => ref.read(shareFileProvider)(file),
  );

  @override
  Widget build(BuildContext context) {
    final download = widget.download;
    final theme = Theme.of(context);
    final extension = fileExtension(download.url);

    return ListTile(
      leading: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download),
      title: Text(download.title),
      subtitle: Text(
        [
          formatBytes(download.fileSize),
          if (extension.isNotEmpty) extension,
          formatDimensions(download.width, download.height),
        ].join('  ·  '),
        style: theme.textTheme.bodySmall,
      ),
      onTap: _busy ? null : _save,
      trailing: IconButton(
        icon: const Icon(Icons.share),
        tooltip: 'Send to another app',
        onPressed: _busy ? null : _share,
      ),
    );
  }
}
