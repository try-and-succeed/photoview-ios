import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The version of the running app, as the build recorded it.
///
/// Comes from `version:` in pubspec.yaml by way of the platform — Android's
/// versionName and versionCode, iOS's bundle versions — so the number on the
/// Info screen is always the one that was built, never a copy that can be
/// forgotten.
final appVersionProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);
