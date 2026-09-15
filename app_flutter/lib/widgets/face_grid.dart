import 'package:flutter/material.dart';

import '../api/models.dart';
import '../screens/person_screen.dart';
import 'protected_image.dart';

const _thumbnailSize = 100.0;

/// Leaves a margin around the detected face rather than cropping tight to it.
const _scaleMultiplier = 0.65;

class FaceSliverGrid extends StatelessWidget {
  final List<FaceGroup> faceGroups;

  const FaceSliverGrid({super.key, required this.faceGroups});

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        crossAxisSpacing: 16,
        mainAxisSpacing: 20,
        childAspectRatio: 0.8,
      ),
      itemCount: faceGroups.length,
      itemBuilder: (context, index) {
        return _FaceTile(face: faceGroups[index]);
      },
    );
  }
}

class _FaceTile extends StatelessWidget {
  final FaceGroup face;

  const _FaceTile({required this.face});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = face.label;

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PersonScreen(faceGroup: face)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaceThumbnail(face: face),
          const SizedBox(height: 6),
          if (label != null)
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            )
          else
            Text(
              'Unlabeled',
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Crops a circular avatar out of the full media thumbnail by scaling and
/// shifting it so the detected face rectangle lands in the centre.
class FaceThumbnail extends StatelessWidget {
  final FaceGroup face;
  final double size;

  const FaceThumbnail({super.key, required this.face, this.size = _thumbnailSize});

  @override
  Widget build(BuildContext context) {
    final rect = face.rectangle;
    final thumbnail = face.thumbnail;

    var scaleX = 1.0;
    var scaleY = 1.0;
    var offset = Offset.zero;

    if (rect != null) {
      final longestSide = rect.width > rect.height ? rect.width : rect.height;
      final scale = longestSide <= 0 ? 1.0 : (1 / longestSide) * _scaleMultiplier;

      // Missing dimensions are stored as 0, so a thumbnail of zero width
      // yields a ratio of 0 and `scale / aspectRatio` below becomes infinity —
      // which makes Transform.scale build an invalid matrix and the tile does
      // not render at all. Checking the ratio covers both dimensions.
      final reported = thumbnail?.aspectRatio ?? 1.0;
      final aspectRatio = reported.isFinite && reported > 0 ? reported : 1.0;

      if (aspectRatio >= 1) {
        scaleX = scale * aspectRatio;
        scaleY = scale;
      } else {
        scaleX = scale;
        scaleY = scale / aspectRatio;
      }

      offset = Offset(
        (0.5 - rect.centerX) * size,
        (0.5 - rect.centerY) * size,
      );
    }

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Transform.scale(
            scaleX: scaleX,
            scaleY: scaleY,
            child: Transform.translate(
              offset: offset,
              child: ProtectedImage(
                url: thumbnail?.url,
                fit: BoxFit.fill,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
