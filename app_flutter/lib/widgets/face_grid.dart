import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../screens/person_screen.dart';
import 'protected_image.dart';

const _thumbnailSize = 100.0;

/// Room for the one line under a face, at the size it will actually be drawn.
///
/// Measured rather than reckoned from the font size: the theme leaves the
/// line height unset, so it comes from the font's own metrics, and the system
/// font setting scales all of it. A factor guessed here was wrong by four
/// hundredths of a pixel, which is still an overflow.
double _labelHeight(BuildContext context) {
  final painter = TextPainter(
    text: TextSpan(
      // Something with an ascender and a descender, so the line is as tall as
      // it ever gets.
      text: 'Ag',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    textScaler: MediaQuery.textScalerOf(context),
    // From the context, not a constant: Arabic and Hebrew are among the
    // languages this app is translated into.
    textDirection: Directionality.of(context),
    maxLines: 1,
  )..layout();

  return painter.height;
}

/// Leaves a margin around the detected face rather than cropping tight to it.
const _scaleMultiplier = 0.65;

class FaceSliverGrid extends StatelessWidget {
  final List<FaceGroup> faceGroups;

  const FaceSliverGrid({super.key, required this.faceGroups});

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      // A height of its own rather than a share of the width: what a tile
      // holds — a round thumbnail of a fixed size and one line — does not get
      // shorter when the screen is narrow, and tied to the width it ran out
      // of room on the narrowest phones.
      //
      // The line is measured rather than guessed, because the system font
      // size scales it and `maxLines: 1` bounds the number of lines, not
      // their height.
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        crossAxisSpacing: 16,
        mainAxisSpacing: 20,
        mainAxisExtent: _thumbnailSize + 6 + _labelHeight(context),
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
              unlabeledFaceLabel(
                AppLocalizations.of(context).personUnlabeled,
                face.imageFaceCount,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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

/// What an unnamed person is called in the grid: how many pictures they are
/// in, then the word.
///
/// Everyone unnamed is called the same thing, so the count is the only thing
/// telling them apart on screen — and the one that says which is worth naming
/// first. **The number comes first** because a tile on a phone held upright
/// is too narrow for both: whatever is cut off should be the word every tile
/// shares, not the part that differs. It also saves guessing where the number
/// belongs in eighteen languages.
///
/// Written with the app language's digit grouping, like the search headings.
/// Named people are left alone: there the name does that job.
///
/// A count of zero is left out: the server sends that for a group it has not
/// counted, and "0 ·" would read as a person in no pictures at all.
@visibleForTesting
String unlabeledFaceLabel(String unlabeled, int count) => count > 0
    ? '${NumberFormat.decimalPattern().format(count)} · $unlabeled'
    : unlabeled;

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
