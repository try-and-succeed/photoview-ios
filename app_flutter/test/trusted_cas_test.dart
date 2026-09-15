import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/trusted_cas.dart';

/// A throwaway self-signed CA, kept here only so the fingerprint below can be
/// checked against a known-good value.
const _testCaPem = '''
-----BEGIN CERTIFICATE-----
MIIDGTCCAgGgAwIBAgIUMzxzp67sdooYNeBtwrBL2CfgPXYwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRUGhvdG92aWV3IFRlc3QgQ0EwHhcNMjYwOTEyMTc0ODI4
WhcNMjYwOTEzMTc0ODI4WjAcMRowGAYDVQQDDBFQaG90b3ZpZXcgVGVzdCBDQTCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKv64Qd8YJTBlVQB7NSPc7k5
xpcpyawBesPP+XqsDhoGxsS7Gawae99uFVpWyM9Hli/dCJHoyErGeSjOaKazqaSu
5hIU2yFCgbZwbiBucZ1pIibwviCX5q2U89a2wL4NJb5hry86F+946sT3DmCsdokg
B0rWejj7X9VJX/f0EpNTZRZSSoCLqmykNckJbdeIijyoBPjLdUqyx7XUUQKxsLTG
iW8EjyWZKOJmGoI6hXeEfLtxKB1UU5il/fsvwYIJc5BBBPLu1HhY3HWKat3WXZgd
nDEKm8SSJtYQZb1/PGQ1gekOrbv41UmNnYCpuQXmmproVyM7rhq0jCyKPuF0ZdMC
AwEAAaNTMFEwHQYDVR0OBBYEFCj5NBFI+KiS2l3Km/IOoNBbCqzwMB8GA1UdIwQY
MBaAFCj5NBFI+KiS2l3Km/IOoNBbCqzwMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
hvcNAQELBQADggEBACOKDndqA3yTuI8zgi7datbcTqZEGnbcbhJRoYe8n7XlgzPz
xIeJ5lhc8tX0IXQNiiuK1pMGMsf/MDeOX1EH/l1j7DfgSgR5RneYz/i18cuKJe0b
iUKSFAWA2TdkpxKgjuJs9iyGtodARrwoL6lkeVQ/mpzseJjjIRbWJwmHAyZVQdIn
0tA1vKEIOxAWdK5v6E/YNRJK+IW1Qwq8mNECFelfX/ZDFzRx+THKgrI4Xa8BPOzB
QQu2bQuKrlVPPJOJm9A/iCUp3xmnh5Gie6dMtTY1CASE+agjT0+zC1dIeb13OfoE
16SIGZen+BtTRfd54Oxov370j5pD0j8C+4Ni0MY=
-----END CERTIFICATE-----
''';

/// What `openssl x509 -fingerprint -sha256` prints for the certificate above.
const _opensslFingerprint =
    'eb74eace9512709bf569ead799ce9ba439c6cd59235e8b64f5b04f8a23711013';

List<int> _der(String pem) =>
    base64.decode(certificateBlocks(pem).single);

void main() {
  group('singleCertificateFrom', () {
    test('fingerprints a PEM the way openssl does', () {
      final certificate = singleCertificateFrom(utf8.encode(_testCaPem));
      expect(certificate.sha256Fingerprint, _opensslFingerprint);
    });

    test('ignores surrounding whitespace and blank lines', () {
      final padded = utf8.encode('\n\n  $_testCaPem  \n\n');
      expect(
        singleCertificateFrom(padded).sha256Fingerprint,
        _opensslFingerprint,
      );
    });

    test('reads a DER file as the same certificate', () {
      // Many tools — Windows' own export dialog included — write a .crt in
      // DER form, and the user cannot tell by looking at it.
      final certificate = singleCertificateFrom(_der(_testCaPem));

      expect(certificate.sha256Fingerprint, _opensslFingerprint);
      expect(certificate.pem.trim(), _testCaPem.trim());
    });

    test('normalises a PEM whose lines are wrapped differently', () {
      final unwrapped =
          '-----BEGIN CERTIFICATE-----\n'
          '${certificateBlocks(_testCaPem).single}\n'
          '-----END CERTIFICATE-----\n';

      final certificate = singleCertificateFrom(utf8.encode(unwrapped));

      expect(certificate.sha256Fingerprint, _opensslFingerprint);
      expect(certificate.pem.trim(), _testCaPem.trim());
    });

    test('carries both encodings, DER being what Apple platforms need', () {
      final certificate = singleCertificateFrom(utf8.encode(_testCaPem));

      expect(certificate.der, _der(_testCaPem));
      expect(utf8.decode(certificate.der, allowMalformed: true),
          isNot(contains('BEGIN CERTIFICATE')));
      expect(certificate.pem, contains('-----BEGIN CERTIFICATE-----'));
    });

    test('refuses a bundle of several certificates', () {
      // The PEM path would trust every certificate in the file while the UI
      // lists one, so the user could not see what they had granted — and the
      // iOS path would silently trust only the first.
      final bundle = utf8.encode('$_testCaPem\n$_testCaPem');

      expect(
        () => singleCertificateFrom(bundle),
        throwsA(
          isA<InvalidCertificateFile>()
              .having((e) => e.message, 'message', contains('2 certificates'))
              .having(
                (e) => e.problem,
                'problem',
                CertificateFileProblem.severalCertificates,
              )
              .having((e) => e.count, 'count', 2),
        ),
      );
    });

    test('rejects a certificate block that is not base64', () {
      final broken = utf8.encode(
        '-----BEGIN CERTIFICATE-----\nnot base64!!\n-----END CERTIFICATE-----',
      );

      expect(
        () => singleCertificateFrom(broken),
        throwsA(isA<InvalidCertificateFile>()),
      );
    });

    test('gives arbitrary bytes a stable identity rather than throwing', () {
      // Whether it is a certificate at all is settled by the TLS stack on
      // import; the fingerprint only has to be reproducible.
      final bytes = utf8.encode('not a certificate');

      expect(
        singleCertificateFrom(bytes).sha256Fingerprint,
        singleCertificateFrom(bytes).sha256Fingerprint,
      );
      expect(
        singleCertificateFrom(bytes).sha256Fingerprint,
        isNot(_opensslFingerprint),
      );
    });
  });

  group('certificateBlocks', () {
    test('finds every block in a bundle', () {
      expect(certificateBlocks('$_testCaPem\n$_testCaPem'), hasLength(2));
    });

    test('ignores a block that was never closed', () {
      expect(
        certificateBlocks('-----BEGIN CERTIFICATE-----\nQUJD\n'),
        isEmpty,
      );
    });

    test('finds nothing in plain text', () {
      expect(certificateBlocks('hello'), isEmpty);
    });
  });

  group('TrustedCa.readableFingerprint', () {
    test('groups the hex digits for reading aloud', () {
      const ca = TrustedCa(name: 'root', sha256: 'abcdef0123456789');
      expect(ca.readableFingerprint, 'ABCD EF01 2345 6789');
    });
  });
}
