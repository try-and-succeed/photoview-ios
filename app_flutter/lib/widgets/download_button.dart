import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/auth.dart';
import '../util/formatting.dart';

/// How long to wait for the response headers.
const _headerTimeout = Duration(seconds: 30);

/// How long a transfer may stall before it is abandoned. An idle deadline,
/// not a total one: a large original over a slow link is fine, a server that
/// stops sending is not — and without it the button stays busy forever.
const _stallTimeout = Duration(seconds: 60);

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
    final client = http.Client();

    try {
      final uri = session.resolve(widget.download.url);
      final request = http.Request('GET', uri)
        ..headers.addAll(session.headers);

      final response = await client.send(request).timeout(_headerTimeout);

      if (response.statusCode == 401 || response.statusCode == 403) {
        // This path bypasses the GraphQL client, so it has to report an
        // expired session itself or the user is left with a download that
        // silently never works. Raised as the same exception the GraphQL
        // client uses, so a rejected sign-in looks the same wherever it
        // surfaces rather than reading as a transport error.
        await ref.read(authProvider.notifier).sessionExpired(session);
        throw const UnauthorizedException();
      }
      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }

      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}${safeFileName(uri)}',
      );

      // Streamed rather than buffered: the sheet offers the original first,
      // and holding a few hundred megabytes in memory can end the app.
      final sink = file.openWrite();
      try {
        await response.stream.timeout(_stallTimeout).pipe(sink);
      } catch (_) {
        await sink.close();
        if (file.existsSync()) await file.delete();
        rethrow;
      }

      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
      }
    } finally {
      client.close();
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
