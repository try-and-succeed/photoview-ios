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

void main() {
  group('fingerprintOfPem', () {
    test('matches the fingerprint openssl reports', () {
      expect(fingerprintOfPem(_testCaPem), _opensslFingerprint);
    });

    test('ignores surrounding whitespace and blank lines', () {
      final padded = '\n\n  $_testCaPem  \n\n';
      expect(fingerprintOfPem(padded), _opensslFingerprint);
    });

    test('is stable for text that is not valid base64', () {
      final first = fingerprintOfPem('not a certificate');
      final second = fingerprintOfPem('not a certificate');

      expect(first, second);
      expect(first, isNot(_opensslFingerprint));
    });
  });

  group('TrustedCa.readableFingerprint', () {
    test('groups the hex digits for reading aloud', () {
      const ca = TrustedCa(name: 'root', sha256: 'abcdef0123456789');
      expect(ca.readableFingerprint, 'ABCD EF01 2345 6789');
    });
  });
}
