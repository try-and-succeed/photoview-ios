import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class InvalidCertificateFile implements Exception {
  final String message;
  const InvalidCertificateFile(this.message);

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
            sha256: fingerprintOfPem(utf8.decode(bytes)),
          ),
        );
      } catch (_) {
        // Skip anything unreadable rather than failing startup.
      }
    }

    _rebuildContext();
  }

  /// Copies [sourcePath] into the store after checking it really is a
  /// certificate the TLS stack will accept.
  Future<TrustedCa> import(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw const InvalidCertificateFile('That file no longer exists.');
    }

    final bytes = await source.readAsBytes();

    // The authority on whether this is usable is the TLS stack itself.
    try {
      SecurityContext(
        withTrustedRoots: false,
      ).setTrustedCertificatesBytes(bytes);
    } catch (error) {
      throw InvalidCertificateFile(
        'That file is not a PEM certificate the system can read. '
        'Export your CA as a .pem or .crt file in PEM format.',
      );
    }

    final fingerprint = fingerprintOfPem(utf8.decode(bytes));
    if (_certificates.any((c) => c.sha256 == fingerprint)) {
      throw const InvalidCertificateFile(
        'That certificate is already trusted.',
      );
    }

    final directory = await _ensureDirectory();
    final name = _uniqueName(directory, _baseName(sourcePath));
    await File('${directory.path}${Platform.pathSeparator}$name.pem')
        .writeAsBytes(bytes);

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
        context.setTrustedCertificatesBytes(file.readAsBytesSync());
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

/// SHA-256 over the certificate's DER bytes, recovered from the PEM body.
///
/// Matches what `openssl x509 -fingerprint -sha256` prints, so a user can
/// check the imported CA against their server.
String fingerprintOfPem(String pem) {
  final body = pem
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();

  try {
    return sha256.convert(base64.decode(body)).toString();
  } catch (_) {
    // Not decodable: fall back to hashing the text so the entry still has a
    // stable identity.
    return sha256.convert(utf8.encode(pem)).toString();
  }
}
