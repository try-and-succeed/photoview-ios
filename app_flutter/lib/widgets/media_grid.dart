import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../state/media_layout.dart';
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

/// A small mark in a tile's top left corner, saying something about the
/// photo that the picture cannot — that its faces are confirmed, say.
class MediaTileBadge {
  final IconData icon;
  final Color color;
  final String label;

  const MediaTileBadge({
    required this.icon,
    required this.color,
    required this.label,
  });
}

/// The photos of a screen, as tiles or as a list of file names — whichever
/// the user chose with [MediaLayoutButton].
class MediaSliverGrid extends ConsumerWidget {
  final List<MediaItem> media;
  final MediaSelection? selection;

  /// The mark for each tile, if any.
  final MediaTileBadge? Function(MediaItem item)? badgeFor;

  /// Whether the gallery opened from a tile frames the faces from the start.
  final bool showFacesInGallery;

  /// Whether the gallery opened from a tile offers to open the photo in its
  /// album — for screens that gather photos from many albums. Left off in
  /// the album itself, where it would lead back to where the user is.
  final bool albumLinkInGallery;

  const MediaSliverGrid({
    super.key,
    required this.media,
    this.selection,
    this.badgeFor,
    this.showFacesInGallery = false,
    this.albumLinkInGallery = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tiles until the stored choice is read: that is the default, and what
    // was there before the choice existed.
    final layout = ref.watch(mediaLayoutProvider).valueOrNull;

    if (layout == MediaLayout.list) {
      return SliverList.builder(
        itemCount: media.length,
        itemBuilder: (context, index) => MediaListRow(
          media: media,
          index: index,
          selection: selection,
          badge: badgeFor?.call(media[index]),
          showFacesInGallery: showFacesInGallery,
          albumLinkInGallery: albumLinkInGallery,
        ),
      );
    }

    return SliverGrid.builder(
      gridDelegate: _gridDelegate,
      itemCount: media.length,
      itemBuilder: (context, index) {
        return MediaThumbnail(
          media: media,
          index: index,
          selection: selection,
          badge: badgeFor?.call(media[index]),
          showFacesInGallery: showFacesInGallery,
          albumLinkInGallery: albumLinkInGallery,
        );
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
  final MediaTileBadge? badge;
  final bool showFacesInGallery;
  final bool albumLinkInGallery;

  const MediaThumbnail({
    super.key,
    required this.media,
    required this.index,
    this.selection,
    this.badge,
    this.showFacesInGallery = false,
    this.albumLinkInGallery = false,
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
          : showFullscreenGallery(
              context,
              media: media,
              initialIndex: index,
              showFaces: showFacesInGallery,
              showAlbumLink: albumLinkInGallery,
            ),
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
          if (badge case final badge?)
            Positioned(
              top: 4,
              left: 4,
              child: Icon(
                badge.icon,
                size: 18,
                color: badge.color,
                semanticLabel: badge.label,
                shadows: const [Shadow(blurRadius: 6, color: Colors.black87)],
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

/// [name] with a place to break after every `_`, `-` and `.`.
///
/// File names rarely have spaces, and a name that does not fit is otherwise
/// broken wherever the line ends — `IMG_2024` split into `IMG_20` and `24`.
/// After a separator is where a reader expects it. The marks are zero-width,
/// so nothing changes for a name that fits.
@visibleForTesting
String breakableFileName(String name) =>
    name.replaceAllMapped(RegExp(r'[_\-.]'), (match) => '${match[0]}​');

/// One photo as a row: a small thumbnail and the whole file name beside it.
///
/// For folders where the name says what the picture does not — scans,
/// documents, numbered series. The name wraps onto as many lines as it needs
/// rather than being cut off. Taps behave exactly as on a tile.
class MediaListRow extends StatelessWidget {
  final List<MediaItem> media;
  final int index;
  final MediaSelection? selection;
  final MediaTileBadge? badge;
  final bool showFacesInGallery;
  final bool albumLinkInGallery;

  const MediaListRow({
    super.key,
    required this.media,
    required this.index,
    this.selection,
    this.badge,
    this.showFacesInGallery = false,
    this.albumLinkInGallery = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = media[index];
    final selection = this.selection;
    final picking = selection?.isActive ?? false;
    final ticked = selection?.contains(item) ?? false;

    return Material(
      color: ticked
          ? theme.colorScheme.primary.withValues(alpha: 0.15)
          : Colors.transparent,
      child: InkWell(
        // As on a tile: while picking, a tap is a tick.
        onTap: () => picking
            ? selection!.onToggle(item)
            : showFullscreenGallery(
                context,
                media: media,
                initialIndex: index,
                showFaces: showFacesInGallery,
                showAlbumLink: albumLinkInGallery,
              ),
        onLongPress: selection == null ? null : () => selection.onToggle(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              if (picking)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Icon(
                    ticked ? Icons.check_circle : Icons.circle_outlined,
                    color: ticked
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              SizedBox.square(
                dimension: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
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
                            size: 24,
                            color: Colors.white,
                            shadows: [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title.isEmpty
                      ? AppLocalizations.of(context).untitledMedia
                      : breakableFileName(item.title),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (badge case final badge?)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Icon(
                    badge.icon,
                    size: 18,
                    color: badge.color,
                    semanticLabel: badge.label,
                  ),
                ),
              if (item.favorite)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Icon(
                    Icons.favorite,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Switches every list of photos between tiles and file names.
///
/// Shows what a tap switches to, as the app's other toggles do.
class MediaLayoutButton extends ConsumerWidget {
  const MediaLayoutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final list =
        ref.watch(mediaLayoutProvider).valueOrNull == MediaLayout.list;

    return IconButton(
      icon: Icon(list ? Icons.grid_view : Icons.view_list),
      tooltip: list ? l10n.mediaLayoutGrid : l10n.mediaLayoutList,
      onPressed: () => ref
          .read(mediaLayoutProvider.notifier)
          .choose(list ? MediaLayout.grid : MediaLayout.list),
    );
  }
}
