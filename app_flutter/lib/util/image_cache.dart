import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Drops cached thumbnails so media from a previous session cannot surface
/// after signing out or switching instances.
Future<void> clearImageCache() async {
  await DefaultCacheManager().emptyCache();
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}
