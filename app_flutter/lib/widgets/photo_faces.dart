import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/capabilities.dart';
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
    // A confirmed face says so in its name as well as in its colour, so the
    // difference does not rest on telling green from white.
    final names = [
      for (final face in found)
        face.verified
            ? '✓ ${describePerson(face.group, l10n)}'
            : describePerson(face.group, l10n),
    ];
    // On top of the style the text inherits — font, spacing — which the
    // measuring below has to see as well: measured without it, the names came
    // out narrower than they are drawn and were cut short on the device.
    final inherited = DefaultTextStyle.of(context).style;
    final styles = [
      for (final face in found)
        inherited.merge(
          TextStyle(
            color: faceStatusColor(face),
            fontSize: unit * 3.5,
            fontStyle: faceGroupIsNamed(face.group) ? null : FontStyle.italic,
          ),
        ),
    ];

    // Measured as drawn: with the photo's own unit and no system text scale,
    // which would make the names grow apart from the photo they label. The
    // width rounded up, so a fraction of a pixel cannot cost a name its end.
    final sizes = [
      for (var i = 0; i < found.length; i++)
        () {
          final painter = TextPainter(
            text: TextSpan(text: names[i], style: styles[i]),
            textDirection: direction,
            textScaler: TextScaler.noScaling,
            maxLines: 1,
          )..layout(maxWidth: size.width - padding.horizontal);
          return Size(
            painter.width.ceilToDouble() + padding.horizontal,
            painter.height + padding.vertical,
          );
        }(),
    ];

    final labels = placeLabels(
      frames: frames,
      labels: sizes,
      area: size,
      gap: unit,
    );

    return Stack(
      children: [
        for (var i = 0; i < found.length; i++)
          Positioned.fromRect(
            rect: frames[i],
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: faceStatusColor(found[i]),
                  width: unit * 0.5,
                ),
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

/// The colour of a face's frame and name: green once a person confirmed it,
/// amber while an automatic run's choice waits for review, white otherwise —
/// which is every face on a server that does not know about confirming.
Color faceStatusColor(PhotoFace face) {
  if (face.verified) return Colors.lightGreenAccent;
  if (face.needsReview) return Colors.amberAccent;
  return Colors.white;
}

/// "Everyone on this photo is right": confirms every face on it, or takes
/// the confirmation back once they all are.
///
/// Only there while the faces are shown, on a server that knows about
/// confirming, and on a photo with faces — confirming what is not seen, or
/// nobody, would mean nothing.
class VerifyPhotoFacesButton extends ConsumerStatefulWidget {
  final String mediaId;

  const VerifyPhotoFacesButton({super.key, required this.mediaId});

  @override
  ConsumerState<VerifyPhotoFacesButton> createState() =>
      _VerifyPhotoFacesButtonState();
}

class _VerifyPhotoFacesButtonState
    extends ConsumerState<VerifyPhotoFacesButton> {
  bool _busy = false;

  /// Sends one decision. Separate from the button so a retry repeats the
  /// sending alone, for the photo and account it was meant for.
  Future<void> _send(String mediaId, bool verified, String? owner) async {
    final l10n = AppLocalizations.of(context);
    // Taken now: the messenger outlives the gallery, so the answer still
    // arrives when it was closed while the request ran.
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) => messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

    setState(() => _busy = true);
    try {
      ensureStillSignedIn(ref, owner);
      await ref
          .read(faceActionsProvider)
          .verifyMedia([mediaId], verified: verified);
      say(verified ? l10n.galleryFacesVerified : l10n.galleryFacesUnverified);
    } catch (error) {
      if (!mounted) {
        say(l10n.galleryFacesVerifyFailed(describeError(error, l10n)));
      } else {
        await showActionFailure(
          context,
          ref,
          error: error,
          message: l10n.galleryFacesVerifyFailed,
          retry: () => _send(mediaId, verified, owner),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hasCapabilityProvider(Capability.faceVerification))) {
      return const SizedBox.shrink();
    }
    final faces = ref.watch(mediaFacesProvider(widget.mediaId)).valueOrNull;
    if (faces == null || faces.isEmpty) return const SizedBox.shrink();

    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    final l10n = AppLocalizations.of(context);
    final allVerified = faces.every((face) => face.verified);

    return IconButton(
      icon: Icon(allVerified ? Icons.verified : Icons.verified_outlined),
      tooltip: allVerified ? l10n.galleryFacesUnverify : l10n.galleryFacesVerify,
      isSelected: allVerified,
      onPressed: () =>
          _send(widget.mediaId, !allVerified, signedInAccount(ref)),
    );
  }
}

/// Where each face's name goes, as a box on the photo.
///
/// Under its face if that is free, else further down, else above — free
/// meaning off every other face and every name already placed, and inside
/// the photo. Names were first put straight under their faces, and on a
/// group photo one covered the next face and the name under it. Where
/// nothing is free, under the face after all — or above it at the bottom
/// edge — moved into the photo if need be: a covered name still beats none.
/// A name that would run off the right edge is moved left to fit.
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

    // Moved up or down into the photo, or to its top when it is taller.
    Rect onPhoto(Rect box) {
      final lowest = area.height - box.height;
      final top = box.top > lowest ? lowest : box.top;
      return at(top < 0 ? 0 : top);
    }

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

    // Kept on the photo all the same: a face as tall as the photo has no room
    // above or below, and a name placed off the photo is cut away entirely.
    final fallback = onPhoto(
      frame.bottom + gap + label.height <= area.height
          ? candidates.first
          : candidates[tries],
    );
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
  // Taken now, while the gallery is open: the messenger sits above it and
  // outlives it, so the answer still arrives when the gallery was closed
  // while the request ran — after a move that went half through, it is the
  // only word on where the photos are.
  final messenger = ScaffoldMessenger.of(context);

  void say(String text) => messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> run(
    Future<String> Function() action, {
    required String Function(String error) failed,
    required Future<void> Function() retry,
    bool retryAnyError = false,
  }) async {
    try {
      say(await action());
    } catch (error) {
      // Without the gallery, no certificate to review and nothing to retry
      // from — but still the message.
      if (!context.mounted) return say(failed(describeError(error, l10n)));
      await showActionFailure(
        context,
        ref,
        error: error,
        message: failed,
        retry: retry,
        retryAnyError: retryAnyError,
      );
    }
  }

  return FaceMove(
    from: describePerson(face.group, l10n),
    exclude: face.group.id,
    run: run,
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
