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
          Stack(
            clipBehavior: Clip.none,
            children: [
              FaceThumbnail(face: face),
              if (face.allVerified == true)
                const PositionedDirectional(
                  end: 0,
                  top: 0,
                  child: VerifiedPersonBadge(),
                ),
              if (face.imageFaceCount > 0)
                PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: PhotoCountBadge(count: face.imageFaceCount),
                ),
            ],
          ),
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
              AppLocalizations.of(context).personUnlabeled,
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

/// How many pictures a person is in, as a small pill on the corner of their
/// round thumbnail.
///
/// On the picture rather than in the line under it: a tile on a phone held
/// upright has room for about fifteen characters, which a name alone already
/// fills — the count beside it cut off either the name or itself. The corner
/// of a square around a circle is empty anyway, so the pill covers almost
/// nothing of the face. With no words in it there is nothing to translate,
/// and it reads the same for the named and the unnamed.
///
/// Written with the app language's digit grouping, like the search headings.
class PhotoCountBadge extends StatelessWidget {
  final int count;

  const PhotoCountBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
        // A ring in the page colour, so the pill stands off the photo
        // whatever colours the photo has.
        border: Border.all(color: scheme.surface, width: 2),
      ),
      child: Text(
        NumberFormat.decimalPattern().format(count),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A green tick on the corner of a person's thumbnail: every face filed under
/// them has been confirmed by someone, so nothing about them is left to check.
///
/// The opposite corner from [PhotoCountBadge], with the same ring in the page
/// colour. The same green as a confirmed face's frame on a photo, a shade
/// darker so a white tick reads on it.
class VerifiedPersonBadge extends StatelessWidget {
  const VerifiedPersonBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      label: AppLocalizations.of(context).peopleAllVerified,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.green.shade600,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.surface, width: 2),
        ),
        child: const Icon(Icons.check, size: 16, color: Colors.white),
      ),
    );
  }
}

/// What an unnamed person is called in a list: how many pictures they are
/// in, then the word.
///
/// Used where there is no thumbnail big enough to carry [PhotoCountBadge] —
/// the person picker. Everyone unnamed is called the same thing, so the count
/// is what tells them apart there. **The number comes first**, so a cut falls
/// on the word every entry shares, not on the part that differs.
///
/// A count of zero is left out: the server sends that for a group it has not
/// counted, and "0 ·" would read as a person in no pictures at all.
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
