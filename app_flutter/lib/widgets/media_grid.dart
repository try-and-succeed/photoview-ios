import 'package:flutter/material.dart';

import '../api/models.dart';
import 'media_details_sheet.dart';
import 'protected_image.dart';

const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 140,
  crossAxisSpacing: 4,
  mainAxisSpacing: 4,
  childAspectRatio: 1,
);

class MediaSliverGrid extends StatelessWidget {
  final List<MediaItem> media;

  const MediaSliverGrid({super.key, required this.media});

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: _gridDelegate,
      itemCount: media.length,
      itemBuilder: (context, index) {
        return MediaThumbnail(media: media, index: index);
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

  const MediaThumbnail({
    super.key,
    required this.media,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final item = media[index];

    return GestureDetector(
      onTap: () => showMediaDetails(context, media: media, initialIndex: index),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ProtectedImage(
            url: item.thumbnail?.url,
            blurhash: item.blurhash,
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
        ],
      ),
    );
  }
}
