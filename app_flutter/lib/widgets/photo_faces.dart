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
              : IgnorePointer(child: _faces(context, found, size, unit)),
        );
      },
    );
  }

  /// The frames, and the names placed where they cover no other face and
  /// no other name.
  Widget _faces(
    BuildContext context,
    List<PhotoFace> found,
    Size size,
    double unit,
  ) {
    final l10n = AppLocalizations.of(context);
    final direction = Directionality.of(context);
    final padding = EdgeInsets.symmetric(
      horizontal: unit * 1.5,
      vertical: unit * 0.5,
    );

    final frames = [
      for (final face in found)
        Rect.fromLTWH(
          face.rectangle.minX * size.width,
          face.rectangle.minY * size.height,
          face.rectangle.width * size.width,
          face.rectangle.height * size.height,
        ),
    ];
    final names = [for (final face in found) describePerson(face.group, l10n)];
    final styles = [
      for (final face in found)
        TextStyle(
          color: Colors.white,
          fontSize: unit * 3.5,
          fontStyle: faceGroupIsNamed(face.group) ? null : FontStyle.italic,
        ),
    ];

    // Measured as drawn: with the photo's own unit and no system text scale,
    // which would make the names grow apart from the photo they label.
    final sizes = [
      for (var i = 0; i < found.length; i++)
        (TextPainter(
              text: TextSpan(text: names[i], style: styles[i]),
              textDirection: direction,
              textScaler: TextScaler.noScaling,
              maxLines: 1,
            )..layout(maxWidth: size.width - padding.horizontal)).size +
            Offset(padding.horizontal, padding.vertical),
    ];

    final labels = placeLabels(
      frames: frames,
      labels: sizes,
      area: size,
      gap: unit,
    );

    return Stack(
      children: [
        for (final frame in frames)
          Positioned.fromRect(
            rect: frame,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: unit * 0.5),
                borderRadius: BorderRadius.circular(unit),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: unit)],
              ),
            ),
          ),
        for (var i = 0; i < found.length; i++)
          Positioned.fromRect(
            rect: labels[i],
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(unit),
              ),
              child: Text(
                names[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: styles[i],
              ),
            ),
          ),
      ],
    );
  }
}

/// Where each face's name goes, as a box on the photo.
///
/// Under its face if that is free, else further down, else above — free
/// meaning off every other face and every name already placed, and inside
/// the photo. Names were first put straight under their faces, and on a
/// group photo one covered the next face and the name under it. Where
/// nothing is free, under the face after all: a covered name still beats
/// none. A name that would run off the right edge is moved left to fit.
///
/// Faces are taken top to bottom, then left to right, so the result does not
/// depend on the order the server listed them in.
List<Rect> placeLabels({
  required List<Rect> frames,
  required List<Size> labels,
  required Size area,
  required double gap,
}) {
  final order = List.generate(frames.length, (i) => i)
    ..sort((a, b) {
      final byTop = frames[a].top.compareTo(frames[b].top);
      return byTop != 0 ? byTop : frames[a].left.compareTo(frames[b].left);
    });

  final placed = List<Rect?>.filled(frames.length, null);
  const tries = 4;

  for (final i in order) {
    final frame = frames[i];
    final label = labels[i];
    final width = label.width < area.width ? label.width : area.width;
    final left = frame.left + width > area.width
        ? area.width - width
        : frame.left;
    Rect at(double top) => Rect.fromLTWH(left, top, width, label.height);

    bool free(Rect box) =>
        box.top >= 0 &&
        box.bottom <= area.height &&
        !placed.any((other) => other != null && other.overlaps(box)) &&
        !frames.indexed.any((f) => f.$1 != i && f.$2.overlaps(box));

    final step = label.height + gap;
    final candidates = [
      for (var k = 0; k < tries; k++) at(frame.bottom + gap + k * step),
      for (var k = 0; k < tries; k++)
        at(frame.top - gap - label.height - k * step),
    ];

    final fallback = frame.bottom + gap + label.height <= area.height
        ? candidates.first
        : candidates[tries];
    placed[i] = candidates.firstWhere(free, orElse: () => fallback);
  }

  return [for (final box in placed) box!];
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
