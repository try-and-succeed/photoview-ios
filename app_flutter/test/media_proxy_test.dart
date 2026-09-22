import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/media_proxy.dart';
import 'package:photoview/api/session.dart';

/// Stands in for Photoview: refuses without the auth cookie, serves ranges,
/// and records what it was asked.
class _Origin {
  final HttpServer server;
  final List<HttpRequest> requests = [];

  _Origin(this.server);

  static const body = 'Photoview video bytes, long enough to slice up.';

  static Future<_Origin> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(server);

    server.listen((request) async {
      origin.requests.add(request);

      if (request.headers.value(HttpHeaders.cookieHeader) != 'auth-token=tok') {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }

      final bytes = utf8.encode(body);
      final range = request.headers.value(HttpHeaders.rangeHeader);

      if (range == null) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
        return;
      }

      final parts = range.replaceFirst('bytes=', '').split('-');
      final start = int.parse(parts[0]);
      final end = parts[1].isEmpty ? bytes.length - 1 : int.parse(parts[1]);
      final slice = bytes.sublist(start, end + 1);

      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        )
        ..contentLength = slice.length
        ..add(slice);
      await request.response.close();
    });

    return origin;
  }

  Uri get endpoint =>
      Uri.parse('http://127.0.0.1:${server.port}/api/graphql');

  Future<void> stop() => server.close(force: true);
}

Future<HttpClientResponse> _get(Uri url, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return await request.close();
  } finally {
    client.close();
  }
}

void main() {
  late _Origin origin;
  late MediaProxy proxy;
  late Session session;

  setUp(() async {
    origin = await _Origin.start();
    proxy = MediaProxy();
    session = Session(
      endpoint: origin.endpoint,
      token: 'tok',
      username: 'admin',
    );
  });

  tearDown(() async {
    await proxy.stop();
    await origin.stop();
  });

  test('plays back what the instance sends', () async {
    final address = await proxy.serve(session, '/api/photo/clip.mp4');

    expect(address.host, '127.0.0.1', reason: 'never off the device');

    final response = await _get(address);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'video/mp4');
    expect(await response.transform(utf8.decoder).join(), _Origin.body);
  });

  test('carries the auth cookie the player cannot know about', () async {
    // Without this the instance answers 403 and the player reports a source
    // error, which is where this whole class comes from.
    final address = await proxy.serve(session, '/api/photo/clip.mp4');
    await _get(address);

    expect(
      origin.requests.single.headers.value(HttpHeaders.cookieHeader),
      'auth-token=tok',
    );
  });

  test('passes a range through in both directions', () async {
    // A video player seeks, and an MP4 whose index sits at the end of the file
    // is unplayable without it.
    final address = await proxy.serve(session, '/api/photo/clip.mp4');
    final response = await _get(address, range: 'bytes=10-19');

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 10-19/${_Origin.body.length}',
    );
    expect(
      await response.transform(utf8.decoder).join(),
      _Origin.body.substring(10, 20),
    );
    expect(
      origin.requests.single.headers.value(HttpHeaders.rangeHeader),
      'bytes=10-19',
    );
  });

  test('an open-ended range works, as the player writes them', () async {
    final address = await proxy.serve(session, '/api/photo/clip.mp4');
    final response = await _get(address, range: 'bytes=30-');

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      await response.transform(utf8.decoder).join(),
      _Origin.body.substring(30),
    );
  });

  test('a refusal upstream is reported as such, not as bytes', () async {
    final wrongToken = Session(
      endpoint: origin.endpoint,
      token: 'stale',
      username: 'admin',
    );
    final address = await proxy.serve(wrongToken, '/api/photo/clip.mp4');

    expect((await _get(address)).statusCode, HttpStatus.forbidden);
  });

  test('nothing but a registered address is served', () async {
    // The port is open on the device; another app must not be able to read
    // the library through it by guessing.
    final address = await proxy.serve(session, '/api/photo/clip.mp4');

    final guessed = address.replace(path: '/somesecret/0');
    expect((await _get(guessed)).statusCode, HttpStatus.notFound);

    final unknownId = address.replace(
      path: '${address.pathSegments.first}/99',
    );
    expect((await _get(unknownId)).statusCode, HttpStatus.notFound);
    expect(origin.requests, isEmpty, reason: 'never even asked upstream');
  });

  test('media named on another host is refused, not fetched', () async {
    // The URL comes from the server's own answer, and an absolute one is taken
    // as it stands. A server that named another host would otherwise have the
    // auth cookie sent there.
    final elsewhere = await _Origin.start();
    addTearDown(elsewhere.stop);

    await expectLater(
      proxy.serve(session, 'http://127.0.0.1:${elsewhere.server.port}/steal.mp4'),
      throwsA(isA<StateError>()),
    );

    expect(elsewhere.requests, isEmpty, reason: 'not even a request');
  });

  test('a path on the instance is served, absolute or not', () async {
    final relative = await proxy.serve(session, '/api/photo/clip.mp4');
    final absolute = await proxy.serve(
      session,
      '${session.endpoint.origin}/api/photo/clip.mp4',
    );

    expect((await _get(relative)).statusCode, HttpStatus.ok);
    expect((await _get(absolute)).statusCode, HttpStatus.ok);
  });

  test('two videos share one server', () async {
    final first = await proxy.serve(session, '/api/photo/one.mp4');
    final second = await proxy.serve(session, '/api/photo/two.mp4');

    expect(first.port, second.port);
    expect(first.path, isNot(second.path));
  });

  test('a session that ended takes its addresses with it', () async {
    final address = await proxy.serve(session, '/api/photo/clip.mp4');
    proxy.clear();

    expect((await _get(address)).statusCode, HttpStatus.notFound);
  });

  test('stopping frees the port', () async {
    final address = await proxy.serve(session, '/api/photo/clip.mp4');
    await proxy.stop();

    await expectLater(_get(address), throwsA(isA<SocketException>()));
  });
}
