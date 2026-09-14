import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/widgets/insecure_notice.dart';

void main() {
  group('InsecureConnectionNotice.riskOfText', () {
    test('warns for certain about an explicit http:// address', () {
      expect(
        InsecureConnectionNotice.riskOfText('http://192.168.0.47:8081'),
        InsecureConnectionRisk.certain,
      );
    });

    test('stays quiet for a schemeless address, which is HTTPS only', () {
      for (final text in ['photoview.lan', '192.168.0.47:8080', 'host/photos']) {
        expect(
          InsecureConnectionNotice.riskOfText(text),
          InsecureConnectionRisk.none,
          reason: '$text has no scheme, so sign-in never uses plain HTTP',
        );
      }
    });

    test('stays quiet for https:// and for an empty field', () {
      expect(
        InsecureConnectionNotice.riskOfText('https://example.com'),
        InsecureConnectionRisk.none,
      );
      expect(
        InsecureConnectionNotice.riskOfText('  HTTPS://example.com '),
        InsecureConnectionRisk.none,
      );
      expect(
        InsecureConnectionNotice.riskOfText('   '),
        InsecureConnectionRisk.none,
      );
    });

    test('ignores the case of the scheme', () {
      expect(
        InsecureConnectionNotice.riskOfText('HTTP://host'),
        InsecureConnectionRisk.certain,
      );
    });

    test('every address the notice calls safe really is HTTPS-only', () {
      // Ties the warning to what login actually does: if candidateBases would
      // try a cleartext endpoint, the field must not be reported as safe.
      const inputs = [
        'https://example.com',
        'http://example.com',
        'photoview.lan',
        '192.168.0.47:8080',
        'host/photos',
        '  HTTP://host ',
      ];

      for (final input in inputs) {
        final bases = PhotoviewClient.candidateBases(input);
        final anyCleartext = bases.any((b) => b.scheme == 'http');
        final quiet =
            InsecureConnectionNotice.riskOfText(input) ==
            InsecureConnectionRisk.none;

        expect(
          quiet && anyCleartext,
          isFalse,
          reason: '$input can be tried over HTTP but raises no warning',
        );
      }
    });
  });

  group('InsecureConnectionNotice.riskOf', () {
    test('an established http endpoint is unencrypted for certain', () {
      expect(
        InsecureConnectionNotice.riskOf(Uri.parse('http://host/api/graphql')),
        InsecureConnectionRisk.certain,
      );
    });

    test('an established https endpoint and no session raise nothing', () {
      expect(
        InsecureConnectionNotice.riskOf(Uri.parse('https://host/api/graphql')),
        InsecureConnectionRisk.none,
      );
      expect(
        InsecureConnectionNotice.riskOf(null),
        InsecureConnectionRisk.none,
      );
    });
  });

  group('InsecureConnectionNotice.hostOfText', () {
    test('reads the host out of a schemeless address', () {
      expect(InsecureConnectionNotice.hostOfText('photoview.lan'), 'photoview.lan');
      expect(
        InsecureConnectionNotice.hostOfText('192.168.0.47:8080/photos'),
        '192.168.0.47',
      );
    });

    test('reads the host out of an address with a scheme', () {
      expect(
        InsecureConnectionNotice.hostOfText('http://example.com:8080'),
        'example.com',
      );
    });

    test('falls back to wording that still reads as a sentence', () {
      expect(InsecureConnectionNotice.hostOfText('   '), 'this server');
    });
  });
}
