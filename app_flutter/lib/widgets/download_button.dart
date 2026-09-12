import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/models.dart';
import '../state/auth.dart';
import '../util/formatting.dart';

/// Downloads one rendition through the authenticated session and hands it to
/// the system share sheet, mirroring the iOS client's download rows.
class DownloadButton extends ConsumerStatefulWidget {
  final MediaDownload download;

  const DownloadButton({super.key, required this.download});

  @override
  ConsumerState<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends ConsumerState<DownloadButton> {
  bool _busy = false;

  Future<void> _download() async {
    final session = ref.read(sessionProvider);
    if (session == null || _busy) return;

    setState(() => _busy = true);

    try {
      final uri = session.resolve(widget.download.url);
      final response = await http.get(uri, headers: session.headers);

      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }

      final directory = await getTemporaryDirectory();
      final name = uri.pathSegments.isEmpty ? 'download' : uri.pathSegments.last;
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(response.bodyBytes);

      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      onTap: _busy ? null : _download,
    );
  }
}
