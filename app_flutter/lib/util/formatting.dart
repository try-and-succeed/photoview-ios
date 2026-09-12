import 'package:intl/intl.dart';

import '../api/models.dart';

class ExifRow {
  final String label;
  final String value;

  const ExifRow(this.label, this.value);
}

/// EXIF fields in the same order and formatting the iOS client used.
List<ExifRow> exifRows(MediaExif exif) {
  final rows = <ExifRow>[];

  void add(String label, String? value) {
    if (value != null && value.isNotEmpty) rows.add(ExifRow(label, value));
  }

  add('Camera', exif.camera);
  add('Maker', exif.maker);
  add('Lens', exif.lens);

  final program = exif.exposureProgram;
  if (program != null) add('Program', exposureProgramName(program));

  final dateShot = exif.dateShot;
  if (dateShot != null) add('Date shot', formatTimestamp(dateShot));

  final exposure = exif.exposure;
  if (exposure != null) add('Exposure', formatExposure(exposure));

  final aperture = exif.aperture;
  if (aperture != null) add('Aperture', 'f/${_trimZeros(aperture)}');

  final iso = exif.iso;
  if (iso != null) add('ISO', '$iso');

  final focalLength = exif.focalLength;
  if (focalLength != null) add('Focal length', '${_trimZeros(focalLength)} mm');

  return rows;
}

String exposureProgramName(int id) => switch (id) {
  0 => 'Not defined',
  1 => 'Manual',
  2 => 'Normal program',
  3 => 'Aperture priority',
  4 => 'Shutter priority',
  5 => 'Creative program',
  6 => 'Action program',
  7 => 'Portrait mode',
  8 => 'Landscape mode',
  9 => 'Bulb',
  _ => 'Unknown',
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
  return '${value.toStringAsFixed(decimals)} ${units[unit]}';
}

String formatDimensions(int width, int height) {
  final formatter = NumberFormat.decimalPattern();
  return '${formatter.format(width)} × ${formatter.format(height)}';
}

String fileExtension(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return '';
  return path.substring(dot + 1).toLowerCase();
}

String _trimZeros(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toString();
}
