import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../util/formatting.dart';
import 'client.dart';
import 'models.dart';
import 'session.dart';

/// How long to wait for the response headers.
const downloadHeaderTimeout = Duration(seconds: 30);

/// How long a transfer may stall before it is abandoned. An idle deadline,
/// not a total one: a large original over a slow link is fine, a server that
/// stops sending is not.
const downloadStallTimeout = Duration(seconds: 60);

/// The user stopped a download.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'Download cancelled.';
}

/// Lets a running download be stopped from outside.
class DownloadCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

/// Removes a file [MediaFileFetcher.fetch] returned, together with the
/// directory of its own it was downloaded into.
///
/// Only that directory: a file anywhere else is removed on its own, so a
/// wrong path can never take a whole folder with it.
Future<void> discardDownload(File file) async {
  final directory = file.parent;
  final isTransferDirectory =
      directory.parent.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ==
          'downloads' &&
      directory.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull
              ?.startsWith('transfer') ==
          true;

  try {
    if (isTransferDirectory) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    } else if (file.existsSync()) {
      await file.delete();
    }
  } on FileSystemException {
    // Cleaning up is best effort; the system clears the temporary directory
    // on its own eventually.
  }
}

/// Where a whole album can be downloaded, as one ZIP of its originals.
///
/// Measured against a live instance: `original` and `thumbnail` answer with a
/// ZIP; `high-res` answers "no media found" for an album of JPEGs, whose
/// high-res rendition is the original itself.
String albumDownloadPath(String albumId) =>
    '/api/download/album/${Uri.encodeComponent(albumId)}/original';

/// The file name an album's ZIP is saved under: its title.
String albumZipFileName(String albumTitle) {
  final name = _safeName(albumTitle);
  return '${name.isEmpty ? 'album' : name}.zip';
}

/// Fetches files from the server through the signed-in session into the
/// app's temporary directory, ready to be saved or shared.
///
/// Streamed rather than buffered: an original can be hundreds of megabytes,
/// and holding that in memory can end the app.
class MediaFileFetcher {
  final http.Client Function() _newClient;
  final Future<Directory> Function() _directory;

  MediaFileFetcher({
    http.Client Function()? newClient,
    Future<Directory> Function()? directory,
  }) : _newClient = newClient ?? http.Client.new,
       _directory = directory ?? getTemporaryDirectory;

  /// Downloads [url] into a file called [fileName] and returns it.
  ///
  /// A status other than 200 is an error, and nothing is written — a server
  /// error page must never end up saved as if it were the photo. 401 throws
  /// [UnauthorizedException], matching the GraphQL client; 403 is a refusal
  /// of this one file, not of the sign-in, and throws
  /// [PermissionDeniedException]. Anything else names the status and the
  /// start of what the server said.
  ///
  /// [onProgress] is told the bytes received so far — the album download
  /// sends no length, so a count is all there is. Cancelling through
  /// [cancellation] closes the connection, removes the partial file and
  /// throws [DownloadCancelledException].
  Future<File> fetch(
    Session session,
    String url, {
    required String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }

    final client = _newClient();
    // Closing the client is what interrupts a request under way, whichever
    // step it is on.
    cancellation?.whenCancelled.then((_) => client.close());

    try {
      return await _fetch(
        client,
        session,
        url,
        fileName,
        onProgress,
        cancellation,
      );
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        throw const DownloadCancelledException();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<File> _fetch(
    http.Client client,
    Session session,
    String url,
    String fileName,
    void Function(int received)? onProgress,
    DownloadCancellation? cancellation,
  ) async {
    final request = http.Request('GET', session.resolve(url))
      ..headers.addAll(session.headers);
    final response = await client.send(request).timeout(downloadHeaderTimeout);

    if (response.statusCode == 401) throw const UnauthorizedException();
    if (response.statusCode == 403) throw const PermissionDeniedException();
    if (response.statusCode != 200) {
      final said = await _shortBody(response);
      throw ApiException(
        'The server returned HTTP ${response.statusCode}'
        '${said.isEmpty ? '' : ': $said'}',
      );
    }

    // A directory of its own for every transfer, with the file keeping the
    // name it will be saved or shared under. A shared file stays in the cache
    // while the receiving app reads it; with one path per name, saving the
    // same photo next would write over that file and then delete it.
    final downloads = Directory(
      '${(await _directory()).path}${Platform.pathSeparator}downloads',
    );
    await downloads.create(recursive: true);
    final directory = await downloads.createTemp('transfer');
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');

    var received = 0;
    final body = cancellation == null
        ? response.stream
        : _untilCancelled(response.stream, cancellation);
    final counted = body.map((chunk) {
      received += chunk.length;
      onProgress?.call(received);
      return chunk;
    });

    final sink = file.openWrite();
    try {
      await counted.timeout(downloadStallTimeout).pipe(sink);
    } catch (_) {
      // pipe may already have closed the sink, in which case closing it again
      // throws "File closed" — which would replace the real error and skip the
      // delete, leaving a partial file behind.
      try {
        await sink.close();
      } catch (_) {}
      await discardDownload(file);
      rethrow;
    }

    return file;
  }

  /// [source], ending with [DownloadCancelledException] as soon as
  /// [cancellation] fires.
  ///
  /// Closing the client normally interrupts the transfer too, but that
  /// depends on the client; this does not, so a cancelled download stops
  /// whatever the connection does.
  static Stream<List<int>> _untilCancelled(
    Stream<List<int>> source,
    DownloadCancellation cancellation,
  ) {
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? subscription;

    out = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
        cancellation.whenCancelled.then((_) {
          if (out.isClosed) return;
          subscription?.cancel();
          out
            ..addError(const DownloadCancelledException())
            ..close();
        });
      },
      onCancel: () => subscription?.cancel(),
    );

    return out.stream;
  }

  /// The first line of an error response, shortened. The download endpoints
  /// answer errors in plain text ("no media found"), which says more than the
  /// status alone.
  static Future<String> _shortBody(http.StreamedResponse response) async {
    try {
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(downloadHeaderTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= 512) break;
      }
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      final line = text.split('\n').first.trim();
      return line.length > 120 ? '${line.substring(0, 120)}…' : line;
    } catch (_) {
      return '';
    }
  }
}

/// The name a downloaded rendition is saved under.
///
/// The original keeps the name it has in the library — the media title, which
/// is the file name — rather than the server's storage name with its random
/// suffix. Other renditions add their purpose, so saving the small version
/// next to the original does not overwrite it. The extension always comes
/// from the file actually served.
String downloadFileName(String mediaTitle, MediaDownload download) {
  final extension = fileExtension(download.url);
  final title = _safeName(mediaTitle);

  final dot = title.lastIndexOf('.');
  final base = dot > 0 ? title.substring(0, dot) : title;
  final titleExtension = dot > 0 ? title.substring(dot + 1).toLowerCase() : '';
  final stem = base.isEmpty ? 'photo' : base;

  final isOriginal = download.title.toLowerCase() == 'original';
  if (isOriginal) {
    if (title.isNotEmpty && (extension.isEmpty || titleExtension == extension)) {
      return title;
    }
    return extension.isEmpty ? stem : '$stem.$extension';
  }

  final purpose = _safeName(download.title)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final suffix = purpose.isEmpty ? '' : '_$purpose';
  return '$stem$suffix${extension.isEmpty ? '' : '.$extension'}';
}

/// [name] without anything that would make it a path or an invalid file name
/// on either platform.
String _safeName(String name) => name
    .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_')
    .trim()
    .replaceAll(RegExp(r'^\.+'), '');
