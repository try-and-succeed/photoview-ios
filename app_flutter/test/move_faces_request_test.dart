import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/session.dart';

/// Stands in for Photoview's GraphQL endpoint and records every query it was
/// sent. [knowsAllowDuplicates] is false for a server from before the switch,
/// which refuses the argument at validation, as such a server does.
class _Server {
  final HttpServer server;
  final bool knowsAllowDuplicates;
  final List<String> queries = [];

  _Server(this.server, this.knowsAllowDuplicates);

  static Future<_Server> start({required bool knowsAllowDuplicates}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _Server(server, knowsAllowDuplicates);

    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final query = body['query'] as String;
      fake.queries.add(query);

      final answer = query.contains('allowDuplicates') && !knowsAllowDuplicates
          ? {
              'errors': [
                {
                  'message':
                      'Unknown argument "allowDuplicates" on field '
                      '"Mutation.moveImageFaces".',
                },
              ],
              'data': null,
            }
          : {
              'data': {
                // The client asks for the type everywhere, as its cache
                // needs it, and the real server always sends it.
                '__typename': 'Mutation',
                'moveImageFaces': {
                  '__typename': 'FaceGroup',
                  'id': '9',
                  'label': 'Anna',
                  'imageFaceCount': 6,
                },
              },
            };

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer));
      await request.response.close();
    });

    return fake;
  }

  PhotoviewClient client() => PhotoviewClient(
    Session(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/api/graphql'),
      token: 'tok',
      username: 'admin',
    ),
  );
}

void main() {
  test('a move turns the duplicate check off, in one request', () async {
    // A sheet of passport photos: the person really is on it more than once,
    // and a move by hand is the user's decision.
    final server = await _Server.start(knowsAllowDuplicates: true);
    addTearDown(() => server.server.close(force: true));

    final label = await server.client().moveImageFaces(['101'], '9');

    expect(label, 'Anna');
    expect(server.queries, hasLength(1));
    expect(server.queries.single, contains('allowDuplicates: true'));
  });

  test('a server without the switch gets the plain move instead', () async {
    final server = await _Server.start(knowsAllowDuplicates: false);
    addTearDown(() => server.server.close(force: true));

    final label = await server.client().moveImageFaces(['101'], '9');

    expect(label, 'Anna');
    expect(server.queries, hasLength(2));
    expect(server.queries.last, isNot(contains('allowDuplicates')));
  });
}
