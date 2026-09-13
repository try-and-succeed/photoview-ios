import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:http/http.dart' as http;
import 'package:photoview/api/client.dart';

OperationException _serverException({
  int? statusCode,
  List<GraphQLError>? bodyErrors,
  Object? cause,
}) => OperationException(
  linkException: ServerException(
    statusCode: statusCode,
    originalException: cause,
    parsedResponse: bodyErrors == null
        ? null
        : Response(
            errors: bodyErrors,
            data: null,
            response: const {},
            context: const Context(),
          ),
  ),
);

OperationException _transport(Object cause) =>
    OperationException(linkException: ServerException(originalException: cause));

GraphQLError _error(String message) => GraphQLError(message: message);

void main() {
  group('PhotoviewClient.isUnauthorized', () {
    test('401 means the sign-in was rejected', () {
      // Measured: an invalid or expired token is turned away by the HTTP
      // middleware with 401 and the body `invalid authorization token`.
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 401)),
        isTrue,
      );
    });

    test('a 401 whose body is not GraphQL still ends the session', () {
      // The shape this server actually produces. Its 401 body is the plain
      // text `invalid authorization token`, which the library cannot parse as
      // GraphQL, so it raises HttpLinkParserException — a sibling of
      // ServerException carrying no statusCode of its own. Reading only
      // ServerException.statusCode meant an expired sign-in was never
      // recognised at all, leaving the user with a parser error and no prompt.
      final exception = OperationException(
        linkException: HttpLinkParserException(
          originalException: const FormatException('not json'),
          originalStackTrace: StackTrace.empty,
          response: http.Response('invalid authorization token', 401),
        ),
      );

      expect(PhotoviewClient.httpStatusOf(exception), 401);
      expect(PhotoviewClient.isUnauthorized(exception), isTrue);
    });

    test('a parser error that is not a 401 leaves the session alone', () {
      final exception = OperationException(
        linkException: HttpLinkParserException(
          originalException: const FormatException('not json'),
          originalStackTrace: StackTrace.empty,
          response: http.Response('<html>gateway timeout</html>', 504),
        ),
      );

      expect(PhotoviewClient.isUnauthorized(exception), isFalse);
    });

    test('403 does not end the session', () {
      // This server never answers 403 for authentication. A 403 from a proxy
      // in front of it says nothing about whether the token is still good, so
      // acting on it would throw away a working session on a guess.
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 403)),
        isFalse,
      );
    });

    test('a server fault does not sign the user out', () {
      for (final status in [500, 502, 503, 504]) {
        expect(
          PhotoviewClient.isUnauthorized(_serverException(statusCode: status)),
          isFalse,
          reason: 'HTTP $status is the server being broken, not a rejection',
        );
      }
    });

    test('404 and 400 do not sign the user out', () {
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 404)),
        isFalse,
      );
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 400)),
        isFalse,
      );
    });

    test('a timeout leaves the session alone', () {
      // The decisive case for a mobile client: dropping to no signal must not
      // log the user out.
      expect(
        PhotoviewClient.isUnauthorized(_transport(TimeoutException('slow'))),
        isFalse,
      );
    });

    test('an unreachable server leaves the session alone', () {
      expect(
        PhotoviewClient.isUnauthorized(
          _transport(const SocketException('Network is unreachable')),
        ),
        isFalse,
      );
    });

    test('an untrusted certificate leaves the session alone', () {
      expect(
        PhotoviewClient.isUnauthorized(_transport(const TlsException('bad'))),
        isFalse,
      );
    });

    test('being refused one thing does not end the session', () {
      // The decisive case. Measured against a live instance: refusing an
      // album, a scan or a field comes back as HTTP 200 with the GraphQL error
      // `unauthorized` — the very same word an unauthenticated request gets.
      // Reading it as a rejected sign-in logged a perfectly valid user out the
      // moment they touched an album they do not own, which is exactly what
      // the scanner and the album tree invite them to do.
      for (final message in [
        'unauthorized',
        'Unauthorized',
        'user is not authorized to view this album',
      ]) {
        expect(
          PhotoviewClient.isUnauthorized(
            OperationException(graphqlErrors: [_error(message)]),
          ),
          isFalse,
          reason: message,
        );
      }
    });

    test('a permission message in a non-200 body is still not a rejection', () {
      expect(
        PhotoviewClient.isUnauthorized(
          _serverException(statusCode: 500, bodyErrors: [_error('unauthorized')]),
        ),
        isFalse,
      );
    });

    test('an unrelated GraphQL error is not a rejection', () {
      expect(
        PhotoviewClient.isUnauthorized(
          OperationException(
            graphqlErrors: [
              _error('Cannot query field "albumTreeChildren" on type "Query"'),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('a 401 wins even when the body talks about permissions', () {
      expect(
        PhotoviewClient.isUnauthorized(
          _serverException(statusCode: 401, bodyErrors: [_error('unauthorized')]),
        ),
        isTrue,
      );
    });

    test('a ServerException with no body at all is not a rejection', () {
      expect(
        PhotoviewClient.isUnauthorized(_serverException()),
        isFalse,
      );
    });
  });

  group('PhotoviewClient.isPermissionDenied', () {
    test('recognises the wordings the server uses for a refusal', () {
      for (final message in [
        'unauthorized',
        'Unauthorized',
        'user is not authorized to view this album',
      ]) {
        expect(
          PhotoviewClient.isPermissionDenied(
            OperationException(graphqlErrors: [_error(message)]),
          ),
          isTrue,
          reason: message,
        );
      }
    });

    test('reads a refusal out of a non-200 body too', () {
      // graphqlErrors is empty for a non-200, so a refusal carried there would
      // be missed if only that list were consulted.
      expect(
        PhotoviewClient.isPermissionDenied(
          _serverException(statusCode: 500, bodyErrors: [_error('unauthorized')]),
        ),
        isTrue,
      );
    });

    test('an ordinary failure is not a refusal', () {
      expect(
        PhotoviewClient.isPermissionDenied(
          _transport(TimeoutException('slow')),
        ),
        isFalse,
      );
      expect(
        PhotoviewClient.isPermissionDenied(
          OperationException(graphqlErrors: [_error('album not found')]),
        ),
        isFalse,
      );
    });
  });

  group('PhotoviewClient.graphqlErrorsOf', () {
    test('collects errors from a 200 response', () {
      final exception = OperationException(graphqlErrors: [_error('boom')]);

      expect(
        PhotoviewClient.graphqlErrorsOf(exception).map((e) => e.message),
        ['boom'],
      );
    });

    test('collects errors carried by a non-200 response', () {
      final exception = _serverException(
        statusCode: 422,
        bodyErrors: [_error('validation failed')],
      );

      expect(
        PhotoviewClient.graphqlErrorsOf(exception).map((e) => e.message),
        ['validation failed'],
      );
    });

    test('collects from both places at once', () {
      final exception = OperationException(
        graphqlErrors: [_error('from data')],
        linkException: ServerException(
          statusCode: 500,
          parsedResponse: Response(
            errors: [_error('from body')],
            data: null,
            response: const {},
            context: const Context(),
          ),
        ),
      );

      expect(
        PhotoviewClient.graphqlErrorsOf(exception).map((e) => e.message),
        ['from data', 'from body'],
      );
    });

    test('is empty rather than throwing when there is no response', () {
      expect(PhotoviewClient.graphqlErrorsOf(_serverException()), isEmpty);
      expect(
        PhotoviewClient.graphqlErrorsOf(
          _transport(const SocketException('down')),
        ),
        isEmpty,
      );
    });
  });
}
