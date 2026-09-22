import 'package:flutter/material.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../screens/album_screen.dart';
import 'fullscreen_gallery.dart';
import 'protected_image.dart';

/// Above this many hits in one section, thumbnails stop being useful.
///
/// A wall of a few hundred pictures cannot be scanned by eye, and each one is
/// a request carrying the session cookie. Past this point a list of names is
/// both faster to load and easier to read.
const compactSearchThreshold = 50;

/// Hard ceiling on what is put on screen per section.
///
/// A user who sets the limit to 0 ("no limit") against a large library gets
/// everything back, and building tens of thousands of rows would make the
/// screen unusable long before it ran out of memory. The remainder is reported
/// as a count rather than silently dropped.
const maxRenderedSearchResults = 500;

enum SearchResultLayout { grid, compact }

/// How one section of results should be shown.
class SearchSectionPlan {
  /// How many entries to build.
  final int shown;

  /// How many the ceiling left out.
  final int hidden;

  final SearchResultLayout layout;

  const SearchSectionPlan({
    required this.shown,
    required this.hidden,
    required this.layout,
  });

  bool get hasHidden => hidden > 0;

  /// Whether the ceiling cut the list, which also means the total is not
  /// known: "show all results" asks for one more than can be shown, so
  /// anything past that was never counted.
  bool get atCeiling => shown >= maxRenderedSearchResults && hidden > 0;
}

/// Decides how to present [count] results.
SearchSectionPlan planSearchSection(int count) {
  final total = count < 0 ? 0 : count;
  final shown = total > maxRenderedSearchResults
      ? maxRenderedSearchResults
      : total;

  return SearchSectionPlan(
    shown: shown,
    hidden: total - shown,
    layout: total > compactSearchThreshold
        ? SearchResultLayout.compact
        : SearchResultLayout.grid,
  );
}

/// A note that the ceiling cut the list short, so a result that is missing
/// never looks like a file that is missing.
class HiddenResultsNote extends StatelessWidget {
  final int hidden;

  /// Whether the list stopped at the ceiling rather than at a known total.
  /// Then [hidden] is only "at least this many", and saying "1 more" — which
  /// is what one hit past the ceiling looks like — would be a lie.
  final bool atCeiling;

  const HiddenResultsNote({
    super.key,
    required this.hidden,
    this.atCeiling = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(
        atCeiling
            ? l10n.searchMoreThanShown(maxRenderedSearchResults)
            : l10n.searchHiddenMore(hidden),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Media as one compact row each, for result sets too large to look at.
///
/// Opens the same sheet the grid does, and is handed the full list so paging
/// through from a row still works.
class MediaResultList extends StatelessWidget {
  final List<MediaItem> media;

  const MediaResultList({super.key, required this.media});

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemCount: media.length,
      itemBuilder: (context, index) {
        final item = media[index];

        return ListTile(
          leading: SizedBox(
            width: 40,
            height: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: ProtectedImage(
                url: item.thumbnail?.url,
                blurhash: item.blurhash,
              ),
            ),
          ),
          title: Text(
            item.title.isEmpty
                ? AppLocalizations.of(context).untitledMedia
                : item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: item.type == MediaType.video
              ? const Icon(Icons.play_circle_outline, size: 20)
              : null,
          onTap: () =>
              showFullscreenGallery(context, media: media, initialIndex: index),
        );
      },
    );
  }
}

/// Albums as one compact row each.
class AlbumResultList extends StatelessWidget {
  final List<AlbumItem> albums;

  const AlbumResultList({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];

        return ListTile(
          leading: const Icon(Icons.photo_album_outlined),
          title: Text(
            album.title.isEmpty
                ? AppLocalizations.of(context).untitledAlbum
                : album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  AlbumScreen(albumId: album.id, title: album.title),
            ),
          ),
        );
      },
    );
  }
}
