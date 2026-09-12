import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth.dart';

/// Photoview serves media behind the same auth cookie as the GraphQL API, so
/// thumbnails cannot be plain network images — every request carries the token.
class ProtectedImage extends ConsumerWidget {
  final String? url;
  final String? blurhash;
  final BoxFit fit;
  final Alignment alignment;

  const ProtectedImage({
    super.key,
    required this.url,
    this.blurhash,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final path = url;

    if (path == null || path.isEmpty || session == null) {
      return _placeholder(context);
    }

    final resolved = session.resolve(path).toString();

    return CachedNetworkImage(
      imageUrl: resolved,
      httpHeaders: session.headers,
      fit: fit,
      alignment: alignment,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, _) => _placeholder(context),
      errorWidget: (context, url, error) {
        // Without this the blurhash stands in for a failed load as well as a
        // pending one, so a broken thumbnail URL looks like a slow one.
        if (kDebugMode) {
          debugPrint('ProtectedImage failed: $url -> $error');
        }
        return _placeholder(context);
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    final hash = blurhash;
    if (hash != null && hash.isNotEmpty) {
      return BlurHash(hash: hash, imageFit: fit);
    }
    return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}
