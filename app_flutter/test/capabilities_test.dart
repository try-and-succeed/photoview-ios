import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';

/// Wordings copied verbatim from a live Photoview instance, so the patterns
/// are matched against what the server really sends rather than a guess.
const _missingField =
    'Cannot query field "albumTreeChildren" on type "Query".';
const _missingPreference =
    'Cannot query field "searchResultLimit" on type "UserPreferences".';
const _missingScanner =
    'Cannot query field "scannerQueueStatus" on type "Query".';
const _missingArgument =
    'Unknown argument "definitelyNotAnArgument" on field "Query.myAlbums".';

/// A field that exists on a type whose own existence is thereby proven — the
/// live server answers this when a subfield name is wrong.
const _wrongSubfield =
    'Cannot query field "albumId" on type "ScannerQueueItem". '
    'Did you mean "album"?';

void main() {
  group('unsupportedFieldIn', () {
    test('names the field of a rejected selection', () {
      expect(unsupportedFieldIn(_missingField), 'albumTreeChildren');
      expect(unsupportedFieldIn(_missingPreference), 'searchResultLimit');
    });

    test('names the argument of a rejected argument', () {
      expect(unsupportedFieldIn(_missingArgument), 'definitelyNotAnArgument');
    });

    test('is null for anything that is not a rejection', () {
      for (final message in [
        'unauthorized',
        'Int cannot represent non-integer value: "x"',
        'introspection disabled',
        'context deadline exceeded',
        '',
      ]) {
        expect(unsupportedFieldIn(message), isNull, reason: message);
      }
    });

    test('reports the type for a field but not for an argument', () {
      expect(unsupportedFieldAndTypeIn(_missingField)?.type, 'Query');
      // The second group of an argument error names a field, not a type, so
      // reporting it as a type would put "Query.myAlbums" where a type belongs.
      expect(unsupportedFieldAndTypeIn(_missingArgument)?.type, isNull);
    });
  });

  group('readProbe', () {
    test('marks a capability supported only on positive evidence', () {
      final states = readProbe(
        data: {
          'myUserPreferences': {
            'searchResultLimit': null,
            'showAlbumTree': null,
          },
          'albumTreeChildren': <dynamic>[],
          'scannerQueueStatus': <dynamic>[],
        },
      );

      expect(states[Capability.searchLimitPreference], CapabilityState.supported);
      expect(states[Capability.albumTreePreference], CapabilityState.supported);
      expect(states[Capability.albumTree], CapabilityState.supported);
      expect(states[Capability.scanner], CapabilityState.supported);
    });

    test('a null value still counts as the field being present', () {
      // The live server returns searchResultLimit: null when the preference is
      // simply unset. Treating null as absent would report a server that has
      // the feature as one that does not.
      final states = readProbe(
        data: {
          'myUserPreferences': {'searchResultLimit': null},
        },
      );

      expect(states[Capability.searchLimitPreference], CapabilityState.supported);
    });

    test('marks a capability unsupported when an error names its field', () {
      final states = readProbe(errorMessages: [_missingField]);

      expect(states[Capability.albumTree], CapabilityState.unsupported);
    });

    test('reads several rejections out of one response', () {
      // GraphQL validation reports every offending field at once, which is
      // what makes a single batched probe worthwhile.
      final states = readProbe(
        errorMessages: [_missingField, _missingScanner, _missingPreference],
      );

      expect(states[Capability.albumTree], CapabilityState.unsupported);
      expect(states[Capability.scanner], CapabilityState.unsupported);
      expect(
        states[Capability.searchLimitPreference],
        CapabilityState.unsupported,
      );
    });

    test('a missing container rules out both preferences at once', () {
      final states = readProbe(
        errorMessages: [
          'Cannot query field "myUserPreferences" on type "Query".',
        ],
      );

      expect(
        states[Capability.searchLimitPreference],
        CapabilityState.unsupported,
      );
      expect(states[Capability.albumTreePreference], CapabilityState.unsupported);
    });

    test('leaves everything unknown when the probe was refused', () {
      // The safety rule: never infer "supported" from the absence of an error.
      // An authorization failure, an error limit or a suppressed cascade would
      // otherwise mark every capability in the batch as present.
      final states = readProbe(errorMessages: ['unauthorized']);

      expect(states, isEmpty);
      expect(
        ServerCapabilities(states).unresolved,
        containsAll(Capability.values),
      );
    });

    test('a wrong subfield does not mark the feature missing', () {
      // The error names a subfield on ScannerQueueItem, which proves the type
      // — and therefore the feature — is there.
      final states = readProbe(errorMessages: [_wrongSubfield]);

      expect(states[Capability.scanner], isNot(CapabilityState.unsupported));
    });

    test('an error wins over data for the same capability', () {
      final states = readProbe(
        data: {'albumTreeChildren': <dynamic>[]},
        errorMessages: [_missingField],
      );

      expect(states[Capability.albumTree], CapabilityState.unsupported);
    });

    test('settles only what it can when the batch is partly rejected', () {
      // A validation failure returns null data, so the fields that were not
      // named stay unknown and are asked about individually.
      final states = readProbe(errorMessages: [_missingField]);
      final capabilities = ServerCapabilities(states);

      expect(capabilities[Capability.albumTree], CapabilityState.unsupported);
      expect(
        capabilities.unresolved,
        containsAll([
          Capability.scanner,
          Capability.searchLimitPreference,
          Capability.albumTreePreference,
        ]),
      );
    });
  });

  group('against a real upstream server', () {
    /// The complete response `photoview/photoview:latest` gives to the batched
    /// probe, captured from a live container. Validation fails, so there is no
    /// data at all and every missing field is named in its own error.
    const upstreamErrors = [
      'Cannot query field "searchResultLimit" on type "UserPreferences".',
      'Cannot query field "showAlbumTree" on type "UserPreferences".',
      'Cannot query field "albumTreeChildren" on type "Query".',
      'Cannot query field "scannerQueueStatus" on type "Query".',
    ];

    test('one round trip settles every capability', () {
      final capabilities = ServerCapabilities(
        readProbe(data: null, errorMessages: upstreamErrors),
      );

      for (final capability in Capability.values) {
        expect(
          capabilities[capability],
          CapabilityState.unsupported,
          reason: capability.name,
        );
      }

      // Nothing left over means no follow-up probes are sent, which is the
      // point of batching.
      expect(capabilities.unresolved, isEmpty);
    });

    test('the preferences container itself is not mistaken for missing', () {
      // Upstream does have myUserPreferences — only the two fields inside it
      // are absent. An implementation that gave up at the container would
      // report the wrong reason, and would also rule out the language
      // preference the app may want later.
      expect(
        upstreamErrors.map(unsupportedFieldIn),
        isNot(contains('myUserPreferences')),
      );
    });
  });

  group('ServerCapabilities', () {
    test('treats an unrecorded capability as unknown, not absent', () {
      expect(
        ServerCapabilities.unknownToAll[Capability.scanner],
        CapabilityState.unknown,
      );
      expect(ServerCapabilities.unknownToAll.has(Capability.scanner), isFalse);
    });

    test('only supported counts as having the feature', () {
      const capabilities = ServerCapabilities({
        Capability.scanner: CapabilityState.supported,
        Capability.albumTree: CapabilityState.unsupported,
      });

      expect(capabilities.has(Capability.scanner), isTrue);
      expect(capabilities.has(Capability.albumTree), isFalse);
      expect(capabilities.has(Capability.searchLimitPreference), isFalse);
    });

    test('a downgrade replaces an earlier supported answer', () {
      const capabilities = ServerCapabilities({
        Capability.scanner: CapabilityState.supported,
      });

      expect(
        capabilities.downgrade(Capability.scanner)[Capability.scanner],
        CapabilityState.unsupported,
      );
    });
  });

  group('UnsupportedFieldException', () {
    test('reads as an explanation rather than a schema error', () {
      final failure = UnsupportedFieldException(
        field: 'albumTreeChildren',
        type: 'Query',
      );

      expect(failure.message, contains('does not support this yet'));
      expect(failure.message, contains('albumTreeChildren'));
      // Still an ApiException, so existing catch blocks keep working.
      expect(failure, isA<ApiException>());
    });

    test('rules out the capabilities its field identifies', () {
      expect(
        UnsupportedFieldException(field: 'scanAlbum').ruledOut,
        {Capability.scanner},
      );
      expect(
        UnsupportedFieldException(field: 'myUserPreferences').ruledOut,
        {Capability.searchLimitPreference, Capability.albumTreePreference},
      );
      expect(UnsupportedFieldException(field: 'somethingElse').ruledOut, isEmpty);
    });
  });

  group('PhotoviewClient.unsupportedFieldException', () {
    test('turns a rejected field into the typed exception', () {
      final failure = PhotoviewClient.unsupportedFieldException(
        OperationException(
          graphqlErrors: [GraphQLError(message: _missingField)],
        ),
      );

      expect(failure, isNotNull);
      expect(failure!.field, 'albumTreeChildren');
      expect(failure.type, 'Query');
    });

    test('leaves an ordinary error alone', () {
      expect(
        PhotoviewClient.unsupportedFieldException(
          OperationException(
            graphqlErrors: [GraphQLError(message: 'album not found')],
          ),
        ),
        isNull,
      );
    });

    test('a rejected sign-in is decided before a missing field', () {
      // Both classifications could match one response; the order matters
      // because only one of them ends the session. A rejected sign-in is a
      // 401 from the middleware, which never carries a GraphQL body of its
      // own — so this is the shape to check.
      final exception = OperationException(
        linkException: ServerException(statusCode: 401),
        graphqlErrors: [GraphQLError(message: _missingField)],
      );

      expect(PhotoviewClient.isUnauthorized(exception), isTrue);
    });

    test('being refused a field is not the same as a missing field', () {
      // A server that has the feature but will not let this user use it says
      // "unauthorized"; one that does not have it names the field. Only the
      // second is worth remembering about the server.
      final refused = OperationException(
        graphqlErrors: [GraphQLError(message: 'unauthorized')],
      );

      expect(PhotoviewClient.unsupportedFieldException(refused), isNull);
      expect(PhotoviewClient.isPermissionDenied(refused), isTrue);
      expect(readProbe(errorMessages: const ['unauthorized']), isEmpty);
    });
  });

  group('probe documents', () {
    test('take no variables, so no document can be sent a stray one', () {
      final documents = [
        capabilityProbeDocument,
        for (final c in Capability.values) singleCapabilityProbeDocument(c),
      ];

      for (final document in documents) {
        expect(document, isNot(contains(r'$')), reason: document);
      }
    });

    test('asks about exactly one capability', () {
      for (final capability in Capability.values) {
        final document = singleCapabilityProbeDocument(capability);
        final others = Capability.values.where((c) => c != capability);

        for (final other in others) {
          // A shared container is legitimately named by two probes; the point
          // is that no probe drags in another capability's own field.
          if (other == Capability.searchLimitPreference ||
              other == Capability.albumTreePreference) {
            if (capability == Capability.searchLimitPreference ||
                capability == Capability.albumTreePreference) {
              continue;
            }
          }

          final ownField = switch (other) {
            Capability.searchLimitPreference => 'searchResultLimit',
            Capability.albumTreePreference => 'showAlbumTree',
            Capability.albumTree => 'albumTreeChildren',
            Capability.scanner => 'scannerQueueStatus',
          };

          expect(
            document,
            isNot(contains(ownField)),
            reason: '${capability.name} probe must not mention $ownField',
          );
        }
      }
    });
  });
}
