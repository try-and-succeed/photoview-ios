import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
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
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 401)),
        isTrue,
      );
    });

    test('403 means the same', () {
      // This server authorizes before it validates the query, so a stale
      // token comes back as either status depending on how it is raised.
      expect(
        PhotoviewClient.isUnauthorized(_serverException(statusCode: 403)),
        isTrue,
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

    test('reads an auth error out of a non-200 body', () {
      // graphqlErrors is empty for a non-200, so an unauthorized message in
      // the body would be missed if only that list were consulted.
      final exception = _serverException(
        statusCode: 500,
        bodyErrors: [_error('unauthorized')],
      );

      expect(PhotoviewClient.isUnauthorized(exception), isTrue);
    });

    test('recognises the wordings the server uses', () {
      for (final message in [
        'unauthorized',
        'Unauthorized',
        'user is not authorized to view this album',
        'invalid token',
      ]) {
        expect(
          PhotoviewClient.isUnauthorized(
            OperationException(graphqlErrors: [_error(message)]),
          ),
          isTrue,
          reason: message,
        );
      }
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

    test('a ServerException with no body at all is not a rejection', () {
      expect(
        PhotoviewClient.isUnauthorized(_serverException()),
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
