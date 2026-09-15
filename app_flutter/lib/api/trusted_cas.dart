import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Why a file cannot be imported as a certificate authority.
enum CertificateFileProblem {
  missing,
  unreadable,
  alreadyTrusted,
  severalCertificates,
  invalidBase64,
}

class InvalidCertificateFile implements Exception {
  final String message;
  final CertificateFileProblem problem;

  /// How many certificates the file holds, for
  /// [CertificateFileProblem.severalCertificates].
  final int count;

  const InvalidCertificateFile(this.message, this.problem, {this.count = 1});

  @override
  String toString() => message;
}

class TrustedCa {
  /// File name the certificate is stored under, and its identity in the UI.
  final String name;
  final String sha256;

  const TrustedCa({required this.name, required this.sha256});

  String get readableFingerprint {
    final upper = sha256.toUpperCase();
    return [
      for (var i = 0; i < upper.length; i += 4)
        upper.substring(i, i + 4 > upper.length ? upper.length : i + 4),
    ].join(' ');
  }
}

/// Certificate authorities the user imported, so certificates issued by their
/// own CA validate like any other.
///
/// This is what makes a private CA workable rather than merely tolerable:
/// Caddy's internal CA, for instance, issues leaf certificates valid for only
/// twelve hours, so pinning individual certificates would prompt the user
/// twice a day. Trusting the CA once covers every certificate it ever issues.
class TrustedCaStore {
  static const _directoryName = 'trusted_cas';

  Directory? _directory;
  final List<TrustedCa> _certificates = [];
  SecurityContext? _context;

  List<TrustedCa> get certificates => List.unmodifiable(_certificates);

  /// Null when nothing has been imported, so the default trust store is used.
  SecurityContext? get securityContext => _context;

  Future<void> load() async {
    final directory = await _ensureDirectory();

    _certificates.clear();
    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pem'))
        .toList();

    for (final file in files) {
      try {
        final bytes = await file.readAsBytes();
        _certificates.add(
          TrustedCa(
            name: _baseName(file.path),
            sha256: singleCertificateFrom(bytes).sha256Fingerprint,
          ),
        );
      } catch (_) {
        // Skip anything unreadable rather than failing startup. The listing
        // then matches what `_rebuildContext` actually trusts, which reads the
        // same files through the same parser.
      }
    }

    _rebuildContext();
  }

  /// Copies [sourcePath] into the store after checking it really is a
  /// certificate the TLS stack will accept.
  Future<TrustedCa> import(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw const InvalidCertificateFile(
        'That file no longer exists.',
        CertificateFileProblem.missing,
      );
    }

    final bytes = await source.readAsBytes();

    // The authority on whether this is usable is the TLS stack itself.
    // Refuses a bundle of several certificates, and accepts DER as well as
    // PEM — plenty of tools export a .crt in DER form.
    final certificate = singleCertificateFrom(bytes);

    try {
      SecurityContext(
        withTrustedRoots: false,
      ).setTrustedCertificatesBytes(certificate.forImport);
    } catch (error) {
      throw const InvalidCertificateFile(
        'That file is not a certificate the system can read. Export your CA '
        'as a .pem or .crt file.',
        CertificateFileProblem.unreadable,
      );
    }

    final fingerprint = certificate.sha256Fingerprint;
    if (_certificates.any((c) => c.sha256 == fingerprint)) {
      throw const InvalidCertificateFile(
        'That certificate is already trusted.',
        CertificateFileProblem.alreadyTrusted,
      );
    }

    final directory = await _ensureDirectory();
    final name = _uniqueName(directory, _baseName(sourcePath));
    // Stored normalised as PEM: it is the portable form, and the DER needed
    // on Apple platforms is derived from it on the way into the context.
    await File(
      '${directory.path}${Platform.pathSeparator}$name.pem',
    ).writeAsString(certificate.pem);

    final imported = TrustedCa(name: name, sha256: fingerprint);
    _certificates.add(imported);
    _rebuildContext();

    return imported;
  }

  Future<void> remove(TrustedCa certificate) async {
    final directory = await _ensureDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}${certificate.name}.pem',
    );
    if (file.existsSync()) await file.delete();

    _certificates.removeWhere((c) => c.sha256 == certificate.sha256);
    _rebuildContext();
  }

  void _rebuildContext() {
    if (_certificates.isEmpty) {
      _context = null;
      return;
    }

    final directory = _directory;
    if (directory == null) return;

    final context = SecurityContext(withTrustedRoots: true);
    for (final certificate in _certificates) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}${certificate.name}.pem',
      );
      if (!file.existsSync()) continue;

      try {
        context.setTrustedCertificatesBytes(
          singleCertificateFrom(file.readAsBytesSync()).forImport,
        );
      } catch (_) {
        // Already validated on import; ignore a file that has since broken.
      }
    }

    _context = context;
  }

  Future<Directory> _ensureDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;

    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}$_directoryName',
    );
    if (!directory.existsSync()) directory.createSync(recursive: true);

    return _directory = directory;
  }

  static String _baseName(String path) {
    final segments = path.split(RegExp(r'[/\\]'));
    var name = segments.isEmpty ? 'certificate' : segments.last;

    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);

    name = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return name.isEmpty ? 'certificate' : name;
  }

  static String _uniqueName(Directory directory, String preferred) {
    var name = preferred;
    var suffix = 2;

    while (File(
      '${directory.path}${Platform.pathSeparator}$name.pem',
    ).existsSync()) {
      name = '$preferred-$suffix';
      suffix++;
    }

    return name;
  }
}

const _pemBegin = '-----BEGIN CERTIFICATE-----';
const _pemEnd = '-----END CERTIFICATE-----';

/// One certificate in both encodings the TLS stack may ask for.
class CertificateBytes {
  /// A normalised single-certificate PEM document.
  final String pem;

  /// The same certificate as raw DER.
  final List<int> der;

  const CertificateBytes({required this.pem, required this.der});

  /// What `SecurityContext.setTrustedCertificatesBytes` accepts here.
  ///
  /// The Dart SDK documents that on iOS the call takes the bytes of a single
  /// DER certificate, while elsewhere it reads PEM or PKCS12. Getting this
  /// wrong means the import silently does nothing on one platform.
  List<int> get forImport =>
      Platform.isIOS || Platform.isMacOS ? der : utf8.encode(pem);

  String get sha256Fingerprint => sha256.convert(der).toString();
}

/// The base64 bodies of every CERTIFICATE block in [text].
List<String> certificateBlocks(String text) {
  final blocks = <String>[];
  var from = 0;

  while (true) {
    final start = text.indexOf(_pemBegin, from);
    if (start == -1) break;

    final bodyStart = start + _pemBegin.length;
    final end = text.indexOf(_pemEnd, bodyStart);
    if (end == -1) break;

    blocks.add(
      text
          .substring(bodyStart, end)
          .replaceAll(RegExp(r'\s'), ''),
    );
    from = end + _pemEnd.length;
  }

  return blocks;
}

/// Reads [bytes] as exactly one certificate, in PEM or DER form.
///
/// A file holding several PEM blocks is refused rather than imported: the
/// non-iOS path would trust every certificate in it while the app lists only
/// one, so the user could not see what they had actually granted.
CertificateBytes singleCertificateFrom(List<int> bytes) {
  String? text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    text = null;
  }

  final blocks = text == null ? const <String>[] : certificateBlocks(text);

  if (blocks.length > 1) {
    throw InvalidCertificateFile(
      'That file holds ${blocks.length} certificates. Import the single CA '
      'certificate on its own, so you can see which one you are trusting.',
      CertificateFileProblem.severalCertificates,
      count: blocks.length,
    );
  }

  if (blocks.length == 1) {
    final List<int> der;
    try {
      der = base64.decode(blocks.single);
    } on FormatException {
      throw const InvalidCertificateFile(
        'That certificate block is not valid base64.',
        CertificateFileProblem.invalidBase64,
      );
    }
    return CertificateBytes(pem: _wrapPem(blocks.single), der: der);
  }

  // No PEM block: many tools, Windows included, export DER-encoded .crt.
  return CertificateBytes(pem: _wrapPem(base64.encode(bytes)), der: bytes);
}

String _wrapPem(String body) {
  final lines = <String>[];
  for (var i = 0; i < body.length; i += 64) {
    lines.add(body.substring(i, i + 64 > body.length ? body.length : i + 64));
  }

  return '$_pemBegin\n${lines.join('\n')}\n$_pemEnd\n';
}
