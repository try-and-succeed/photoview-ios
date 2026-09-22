import 'package:flutter/material.dart';

import '../api/models.dart';
import 'fullscreen_gallery.dart';
import 'protected_image.dart';

const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 140,
  crossAxisSpacing: 4,
  mainAxisSpacing: 4,
  childAspectRatio: 1,
);

/// How a grid behaves when the user is picking things out of it.
///
/// Absent — which is every grid but the album's — the tiles work as they
/// always have: a tap opens the picture and a long press does nothing.
class MediaSelection {
  /// Ids ticked so far. Empty means the mode is not running.
  final Set<String> selected;

  /// A tile was tapped while picking, or long-pressed to start.
  final void Function(MediaItem item) onToggle;

  const MediaSelection({required this.selected, required this.onToggle});

  bool get isActive => selected.isNotEmpty;

  bool contains(MediaItem item) => selected.contains(item.id);
}

class MediaSliverGrid extends StatelessWidget {
  final List<MediaItem> media;
  final MediaSelection? selection;

  const MediaSliverGrid({super.key, required this.media, this.selection});

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: _gridDelegate,
      itemCount: media.length,
      itemBuilder: (context, index) {
        return MediaThumbnail(media: media, index: index, selection: selection);
      },
    );
  }
}

/// Non-sliver variant for short, non-paginated lists.
class MediaGrid extends StatelessWidget {
  final List<MediaItem> media;

  const MediaGrid({super.key, required this.media});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: _gridDelegate,
      itemCount: media.length,
      itemBuilder: (context, index) =>
          MediaThumbnail(media: media, index: index),
    );
  }
}

class MediaThumbnail extends StatelessWidget {
  final List<MediaItem> media;
  final int index;
  final MediaSelection? selection;

  const MediaThumbnail({
    super.key,
    required this.media,
    required this.index,
    this.selection,
  });

  @override
  Widget build(BuildContext context) {
    final item = media[index];
    final selection = this.selection;
    final picking = selection?.isActive ?? false;
    final ticked = selection?.contains(item) ?? false;

    return GestureDetector(
      // The picture first: it is what the tap was about. Camera data,
      // downloads and links sit behind the gallery's info button, which is
      // where they are wanted far less often. While picking, though, a tap
      // is a tick — opening a photo from under the user's finger mid-choice
      // would be the surprise.
      onTap: () => picking
          ? selection!.onToggle(item)
          : showFullscreenGallery(context, media: media, initialIndex: index),
      onLongPress: selection == null ? null : () => selection.onToggle(item),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ProtectedImage(
            url: item.thumbnail?.url,
            blurhash: item.blurhash,
          ),
          if (ticked)
            ColoredBox(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
            ),
          if (item.type == MediaType.video)
            const Center(
              child: Icon(
                Icons.play_arrow,
                size: 32,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
          if (item.favorite)
            const Positioned(
              top: 4,
              right: 4,
              child: Icon(
                Icons.favorite,
                size: 16,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          // Shown for every tile while picking, ticked or not: an empty
          // circle is what says the tile can be chosen at all.
          if (picking)
            Positioned(
              bottom: 4,
              left: 4,
              child: Icon(
                ticked ? Icons.check_circle : Icons.circle_outlined,
                size: 22,
                color: Colors.white,
                shadows: const [Shadow(blurRadius: 6, color: Colors.black87)],
              ),
            ),
        ],
      ),
    );
  }
}
