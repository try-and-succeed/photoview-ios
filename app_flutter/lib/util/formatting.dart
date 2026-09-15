import 'package:intl/intl.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';

class ExifRow {
  final String label;
  final String value;

  const ExifRow(this.label, this.value);
}

/// EXIF fields in the same order and formatting the iOS client used, labelled
/// in the app language.
List<ExifRow> exifRows(MediaExif exif, AppLocalizations l10n) {
  final rows = <ExifRow>[];

  void add(String label, String? value) {
    if (value != null && value.isNotEmpty) rows.add(ExifRow(label, value));
  }

  add(l10n.exifCamera, exif.camera);
  add(l10n.exifMaker, exif.maker);
  add(l10n.exifLens, exif.lens);

  final program = exif.exposureProgram;
  if (program != null) {
    add(l10n.exifProgram, exposureProgramName(program, l10n));
  }

  final dateShot = exif.dateShot;
  if (dateShot != null) add(l10n.exifDateShot, formatTimestamp(dateShot));

  final exposure = exif.exposure;
  if (exposure != null) add(l10n.exifExposure, formatExposure(exposure));

  final aperture = exif.aperture;
  if (aperture != null) add(l10n.exifAperture, 'f/${_trimZeros(aperture)}');

  final iso = exif.iso;
  if (iso != null) add(l10n.exifIso, '$iso');

  final focalLength = exif.focalLength;
  if (focalLength != null) {
    add(l10n.exifFocalLength, '${_trimZeros(focalLength)} mm');
  }

  return rows;
}

String exposureProgramName(int id, AppLocalizations l10n) => switch (id) {
  0 => l10n.exposureNotDefined,
  1 => l10n.exposureManual,
  2 => l10n.exposureNormal,
  3 => l10n.exposureAperturePriority,
  4 => l10n.exposureShutterPriority,
  5 => l10n.exposureCreative,
  6 => l10n.exposureAction,
  7 => l10n.exposurePortrait,
  8 => l10n.exposureLandscape,
  9 => l10n.exposureBulb,
  _ => l10n.exposureUnknown,
};

/// The name of a download rendition in the app language.
///
/// The server sends fixed English titles; one it adds later is shown as sent
/// rather than hidden.
String renditionName(String serverTitle, AppLocalizations l10n) =>
    switch (serverTitle) {
      'Original' => l10n.renditionOriginal,
      'Large' => l10n.renditionLarge,
      'Small' => l10n.renditionSmall,
      'Video thumbnail' => l10n.renditionVideoThumbnail,
      'Web optimized video' => l10n.renditionWebVideo,
      _ => serverTitle,
    };

/// Shutter speeds below a second read as a fraction, as photographers expect.
String formatExposure(double value) {
  if (value <= 0) return '$value';
  if (value >= 1) return '${_trimZeros(value)} s';
  return '1/${(1 / value).round()}';
}

String formatTimestamp(String raw) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  return DateFormat.yMMMd().add_Hm().format(parsed.toLocal());
}

String formatDay(DateTime day) => DateFormat.yMMMd().format(day);

String formatBytes(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;

  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }

  final decimals = unit == 0 || value >= 100 ? 0 : 1;
  final number = NumberFormat.decimalPattern()
    ..minimumFractionDigits = decimals
    ..maximumFractionDigits = decimals;
  return '${number.format(value)} ${units[unit]}';
}

String formatDimensions(int width, int height) {
  final formatter = NumberFormat.decimalPattern();
  return '${formatter.format(width)} × ${formatter.format(height)}';
}

/// A download URL reduced to a plain file name, safe to join onto a directory.
///
/// `Uri.pathSegments` percent-decodes, so a segment containing `%2F` or `%5C`
/// comes back carrying a separator and would place the file outside the
/// directory it was meant for.
String safeFileName(Uri uri) {
  final raw = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final name = raw.split(RegExp(r'[/\\]')).last.trim();

  if (name.isEmpty || name == '.' || name == '..') return 'download';
  return name;
}

String fileExtension(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return '';
  return path.substring(dot + 1).toLowerCase();
}

/// Whole numbers without decimals, others with the language's separator.
String _trimZeros(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return (NumberFormat.decimalPattern()..maximumFractionDigits = 6).format(
    value,
  );
}
