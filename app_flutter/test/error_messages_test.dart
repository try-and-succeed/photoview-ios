import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/capabilities.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/media_files.dart';
import 'package:photoview/api/trusted_cas.dart';
import 'package:photoview/l10n/app_localizations.dart';
import 'package:photoview/l10n/error_messages.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _de = lookupAppLocalizations(const Locale('de'));

void main() {
  group('describeError', () {
    test('words failures the app can name in the app language', () {
      expect(
        describeError(const UnauthorizedException(), _de),
        'Deine Anmeldung wird nicht mehr akzeptiert.',
      );
      expect(
        describeError(const PermissionDeniedException(), _de),
        'Dein Konto darf das nicht.',
      );
      expect(
        describeError(
          const ApiException(
            'The server returned HTTP 400: no media found',
            problem: ApiProblem.httpStatus,
            detail: '400: no media found',
          ),
          _de,
        ),
        'Der Server antwortete mit HTTP 400: no media found.',
      );
      expect(
        describeError(const DownloadCancelledException(), _de),
        'Download abgebrochen',
      );
      expect(describeError(TimeoutException('slow'), _de), contains('zu lange'));
    });

    test('keeps the address in the plain HTTP hint usable', () {
      final text = describeError(
        const LoginFailure(
          'did not complete a TLS handshake',
          problem: ApiProblem.noTlsHandshake,
          detail: '192.168.0.47:8081',
        ),
        _de,
      );

      expect(text, contains('http://192.168.0.47:8081'));
      expect(text, startsWith('192.168.0.47:8081 hat keinen TLS-Handshake'));
    });

    test('shows what the server said in its own words as sent', () {
      // A GraphQL error or a refused sign-in: the app cannot know every
      // message a server produces, so it does not pretend to translate them.
      expect(
        describeError(const ApiException('invalid credentials'), _de),
        'invalid credentials',
      );
      expect(
        describeError(const LoginFailure('username or password wrong'), _de),
        'username or password wrong',
      );
    });

    test('names a missing server feature by its field', () {
      expect(
        describeError(UnsupportedFieldException(field: 'albumTreeChildren'), _en),
        'Your Photoview server does not support this yet '
        '(it has no "albumTreeChildren").',
      );
    });

    test('explains a refused certificate file', () {
      expect(
        describeError(
          const InvalidCertificateFile(
            'That file holds 2 certificates.',
            CertificateFileProblem.severalCertificates,
            count: 2,
          ),
          _de,
        ),
        startsWith('Die Datei enthält mehrere Zertifikate (2).'),
      );
    });

    test('an unknown failure still says what it was', () {
      expect(
        describeError(
          const ApiException(
            'StateError: x',
            problem: ApiProblem.unknown,
            detail: 'StateError: x',
          ),
          _de,
        ),
        'StateError: x',
      );
      expect(describeError(null, _de), 'Unbekannter Fehler');
    });

    test('every problem has wording', () {
      for (final problem in ApiProblem.values) {
        final text = describeError(
          ApiException('x', problem: problem, detail: 'd'),
          _en,
        );
        expect(text, isNotEmpty, reason: '$problem');
        expect(text, isNot('x'), reason: '$problem falls back to English');
      }
    });
  });
}
