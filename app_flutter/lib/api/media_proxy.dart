import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'session.dart';

/// Hands media to the platform video player from inside the app.
///
/// The player is native — ExoPlayer on Android — and does its own TLS against
/// the *system* trust store. A certificate the user accepted in this app means
/// nothing to it: a self-hosted server with its own authority (Caddy's, say)
/// fails with "Trust anchor for certification path not found", which reaches
/// the user as an unexplained "Source error". Everything else is unaffected,
/// because queries, images and downloads go through Dart's `HttpClient`, which
/// is where the accepted certificates live.
///
/// So the player is pointed at this server on the loopback interface, and it
/// fetches the media with the client that does trust the certificate and
/// passes the bytes through. Range requests are forwarded both ways: a video
/// player seeks, and an MP4 whose index sits at the end of the file is
/// unplayable without it.
class MediaProxy {
  MediaProxy({HttpClient Function()? openClient, Future<HttpServer> Function()? bind})
    : _openClient = openClient ?? HttpClient.new,
      _bind = bind ?? _bindLoopback;

  /// The client used upstream. A seam for tests; in the app it is the plain
  /// constructor, which picks up the global [HttpOverrides] — the whole point.
  final HttpClient Function() _openClient;

  /// How the server is opened. A seam too: a test that wants to know whether
  /// a server was left running has to get hold of it first.
  final Future<HttpServer> Function() _bind;

  static Future<HttpServer> _bindLoopback() =>
      HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  /// Guards the port against anything else running on the device: the path
  /// carries a secret that only the player is ever told.
  final String _secret = _randomSecret();

  final Map<String, _Target> _targets = {};

  HttpServer? _server;
  Future<HttpServer>? _starting;
  int _nextId = 0;

  /// Set by [stop], and never cleared: a stopped proxy is not restarted.
  ///
  /// Stopping happens when the session changes, and a bind started for the
  /// old session can still be in flight. Without this its callback would
  /// install a server nobody holds any more — an open port for the rest of
  /// the app's life, reachable with addresses registered after the stop.
  bool _stopped = false;

  /// Registers [mediaUrl] of [session] and returns the address to play.
  ///
  /// Refuses anything that does not resolve onto the signed-in instance. The
  /// URL comes from the server's own answer, and [Session.resolve] takes an
  /// absolute one as it stands — so a server that named another host would
  /// have this send the auth cookie there. No Photoview does that; a
  /// compromised or hostile one would only have to ask.
  Future<Uri> serve(Session session, String mediaUrl) async {
    final url = session.resolve(mediaUrl);
    if (!_sameOrigin(url, session.endpoint)) {
      throw StateError('$mediaUrl is not on ${session.endpoint.host}');
    }

    final server = await _ensureServer();

    // Checked again on the far side of the await: the session can have ended
    // while the server was still coming up, and registering now would hand
    // out an address on a server that is being taken down.
    if (_stopped) throw StateError('The player service has been stopped');

    final id = '${_nextId++}';
    _targets[id] = _Target(url, session.headers);

    return Uri.parse('http://127.0.0.1:${server.port}/$_secret/$id');
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// Forgets everything registered so far, for a session that has ended.
  void clear() => _targets.clear();

  Future<void> stop() async {
    _stopped = true;
    clear();

    final server = _server;
    final starting = _starting;
    _server = null;
    _starting = null;

    await server?.close(force: true);

    // A bind that was still in flight closes itself, but only once it lands.
    // Waiting for it here means the port is really gone by the time this
    // returns, which is what a test — and a session switch — can rely on.
    if (starting != null) {
      try {
        await (await starting).close(force: true);
      } catch (_) {
        // Either the bind failed or its callback already closed the server.
      }
    }
  }

  Future<HttpServer> _ensureServer() {
    if (_stopped) {
      return Future.error(StateError('The player service has been stopped'));
    }

    final running = _server;
    if (running != null) return Future.value(running);

    // Started once even if two videos open at the same moment: the second
    // caller waits for the first bind instead of racing it.
    return _starting ??= _bind().then((server) {
      if (_stopped) {
        // Stopped while this was binding, so it is closed here rather than
        // ever being listened on. `stop` waits for this same future and would
        // close it too — deliberately both, because either alone leaves a
        // window: without this one a handler is attached to a server nobody
        // holds, without the wait `stop` returns while the port is still
        // coming up.
        server.close(force: true);
        throw StateError('The player service has been stopped');
      }

      _server = server;
      server.listen(_handle, onError: (_) {});
      return server;
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final target = segments.length == 2 && segments[0] == _secret
        ? _targets[segments[1]]
        : null;

    if (target == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final client = _openClient();
    try {
      final upstream = await client.openUrl(request.method, target.url);
      target.headers.forEach(upstream.headers.set);

      // What the player asks for, unchanged. Without this every seek would
      // fetch the file from the beginning.
      for (final name in const [
        HttpHeaders.rangeHeader,
        HttpHeaders.ifRangeHeader,
      ]) {
        final value = request.headers.value(name);
        if (value != null) upstream.headers.set(name, value);
      }

      final response = await upstream.close();

      request.response.statusCode = response.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }

      // Only when the server named one: a length that does not match the body
      // ends the connection mid-video.
      if (response.contentLength >= 0) {
        request.response.contentLength = response.contentLength;
      }

      // `pipe` closes the response itself — closing it again in the error
      // path throws "File closed" over whatever really went wrong.
      await response.pipe(request.response);
    } catch (_) {
      // The player hanging up mid-stream lands here as well as a server that
      // failed, and neither is worth more than ending this one request.
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // Already gone.
      }
    } finally {
      client.close();
    }
  }
}

class _Target {
  final Uri url;
  final Map<String, String> headers;

  const _Target(this.url, this.headers);
}

String _randomSecret() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
