import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/library.dart';
import '../state/people_order.dart' show faceGroupIsNamed;
import 'action_failure.dart';
import 'face_move.dart';

/// The faces found on a photo, drawn over it: a frame around each, with the
/// name of the person it is filed under.
///
/// Answers who is on a photo, and — on a photo with several people — which
/// rectangle is whose. That is the part a list of names cannot say: to put a
/// photo under a second person, it is that person's face that has to be
/// filed, and here it can be seen which one that is.
///
/// Only a picture: the gallery's photo view takes every tap on the photo for
/// itself, so a frame could not be tapped. The gallery works out what was
/// tapped instead — see [photoPointAt] and [faceAt] — and calls
/// [assignPhotoFace].
///
/// Laid over the photo at the photo's own size, so the frames zoom and pan
/// with it. Everything is measured in parts of the photo rather than in
/// pixels for the same reason: the gallery scales the photo, and these with
/// it, to whatever the screen holds.
class PhotoFacesOverlay extends ConsumerWidget {
  final String mediaId;

  const PhotoFacesOverlay({super.key, required this.mediaId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faces = ref.watch(mediaFacesProvider(mediaId));

    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        // One unit for lines and type, so they keep their proportion to the
        // photo whatever size it is shown at.
        final unit = size.shortestSide / 100;

        return faces.when(
          loading: () => const SizedBox.shrink(),
          error: (error, _) => _Notice(
            text: describeError(error, AppLocalizations.of(context)),
            unit: unit,
          ),
          data: (found) => found.isEmpty
              ? _Notice(
                  text: AppLocalizations.of(context).galleryFacesNone,
                  unit: unit,
                )
              : IgnorePointer(
                  child: Stack(
                    children: [
                      for (final face in found)
                        ..._frame(context, face, size, unit),
                    ],
                  ),
                ),
        );
      },
    );
  }

  /// The frame around [face] and the name under it.
  List<Widget> _frame(
    BuildContext context,
    PhotoFace face,
    Size size,
    double unit,
  ) {
    final l10n = AppLocalizations.of(context);
    final rect = face.rectangle;
    final left = rect.minX * size.width;
    final top = rect.minY * size.height;
    final width = rect.width * size.width;
    final height = rect.height * size.height;
    final labelHeight = unit * 6;

    // Under the face, or above it when the face is at the bottom edge.
    final below = top + height + unit + labelHeight <= size.height;

    return [
      Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white, width: unit * 0.5),
            borderRadius: BorderRadius.circular(unit),
            boxShadow: [BoxShadow(color: Colors.black54, blurRadius: unit)],
          ),
        ),
      ),
      Positioned(
        left: left,
        top: below ? top + height + unit : null,
        bottom: below ? null : size.height - top + unit,
        // Wider than the face may be — a name is often longer than a face is
        // wide — but never past the photo's edge.
        width: (size.width - left).clamp(0, width * 3),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: unit * 1.5,
              vertical: unit * 0.5,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(unit),
            ),
            child: Text(
              describePerson(face.group, l10n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: unit * 3.5,
                fontStyle: faceGroupIsNamed(face.group)
                    ? null
                    : FontStyle.italic,
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

/// Files [face] under someone else, a new person, or nobody — the same dialog
/// and question as on a person's own screen.
Future<void> assignPhotoFace(
  BuildContext context,
  WidgetRef ref,
  PhotoFace face,
) {
  final l10n = AppLocalizations.of(context);

  return FaceMove(
    from: describePerson(face.group, l10n),
    exclude: face.group.id,
    run: (action, {required failed, required retry}) async {
      try {
        final done = await action();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(done)));
      } catch (error) {
        if (!context.mounted) return;
        await showActionFailure(
          context,
          ref,
          error: error,
          message: failed,
          retry: retry,
        );
      }
    },
  ).pickAndMove(
    context,
    ref,
    faceIds: [face.id],
    count: 1,
    title: l10n.galleryFaceAssignPick,
  );
}

/// Where on the photo, in parts of its width and height, a tap on the photo
/// view landed — or null when it landed beside the photo.
///
/// The photo view draws the photo at [childSize] times [scale], centred in
/// [viewport] and then shifted by [position]; this undoes that. A null
/// [scale] is the view's own before the first zoom: the photo fitted whole.
Offset? photoPointAt({
  required Offset tap,
  required Size viewport,
  required Size childSize,
  required double? scale,
  required Offset position,
}) {
  if (childSize.isEmpty || viewport.isEmpty) return null;
  final shown =
      scale ??
      (viewport.width / childSize.width < viewport.height / childSize.height
          ? viewport.width / childSize.width
          : viewport.height / childSize.height);
  if (shown <= 0) return null;

  final centre = viewport.center(Offset.zero) + position;
  final local = (tap - centre) / shown;
  final x = local.dx / childSize.width + 0.5;
  final y = local.dy / childSize.height + 0.5;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return Offset(x, y);
}

/// The face at [point], in parts of the photo, if any.
///
/// The smallest that holds it, for faces in front of one another: the one
/// behind is the larger box around the smaller. A little slack around each,
/// because a face frame is small under a fingertip.
PhotoFace? faceAt(List<PhotoFace> faces, Offset point, {double slack = 0.02}) {
  PhotoFace? best;
  for (final face in faces) {
    final r = face.rectangle;
    final hit =
        point.dx >= r.minX - slack &&
        point.dx <= r.maxX + slack &&
        point.dy >= r.minY - slack &&
        point.dy <= r.maxY + slack;
    if (!hit) continue;
    if (best == null ||
        r.width * r.height < best.rectangle.width * best.rectangle.height) {
      best = face;
    }
  }
  return best;
}

/// A line at the foot of the photo, for when there are no frames to draw.
class _Notice extends StatelessWidget {
  final String text;
  final double unit;

  const _Notice({required this.text, required this.unit});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Padding(
      padding: EdgeInsets.all(unit * 3),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: unit * 3,
          vertical: unit * 1.5,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(unit * 2),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: unit * 3.5),
        ),
      ),
    ),
  );
}
