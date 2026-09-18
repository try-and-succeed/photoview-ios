import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/auth.dart';
import '../state/library.dart';
import '../util/formatting.dart';
import 'download_button.dart';
import 'exif_table.dart';
import 'fullscreen_gallery.dart';
import 'protected_image.dart';

void showMediaDetails(
  BuildContext context, {
  required List<MediaItem> media,
  required int initialIndex,
  bool showPreview = true,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => MediaDetailsSheet(
      media: media,
      initialIndex: initialIndex,
      showPreview: showPreview,
    ),
  );
}

class MediaDetailsSheet extends ConsumerStatefulWidget {
  final List<MediaItem> media;
  final int initialIndex;

  /// Whether to head the sheet with the picture.
  ///
  /// False when the gallery opens it: the photo is already on screen behind
  /// the sheet, and a preview that reopens the gallery would stack a second
  /// one on top of the first.
  final bool showPreview;

  const MediaDetailsSheet({
    super.key,
    required this.media,
    required this.initialIndex,
    this.showPreview = true,
  });

  @override
  ConsumerState<MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends ConsumerState<MediaDetailsSheet> {
  late int _index = widget.initialIndex;

  MediaItem get _item => widget.media[_index];

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(mediaDetailsProvider(_item.id));
    final l10n = AppLocalizations.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (widget.showPreview) ...[
            _preview(context),
            const SizedBox(height: 12),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              details.valueOrNull?.title ?? l10n.loading,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          // Where the photo lives. Worth saying in the gallery above all,
          // which can be reached from a search or the map, where the album
          // never appears on screen at all.
          if (details.valueOrNull?.album case final album?) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                album.crumbs.map((a) => a.title).join(' / '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const SizedBox(height: 16),
          ...details.when(
            loading: () => [
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
            ],
            error: (error, _) => [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.mediaDetailsFailed(describeError(error, l10n)),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            data: (data) => [
              // Saying that there is none beats a gap the reader has to
              // interpret — a photo without EXIF is common enough (a
              // screenshot, an export that stripped it).
              if (data.exif == null || exifRows(data.exif!, l10n).isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.galleryNoCameraData,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                ExifTable(exif: data.exif!),
              if (data.downloads.isNotEmpty) ...[
                _SectionHeader(title: l10n.sectionDownload),
                for (final download in data.downloads)
                  DownloadButton(download: download, mediaTitle: data.title),
              ],
              // Public links, not the share sheet — named apart from the
              // "send to another app" button on each download above.
              _SectionHeader(title: l10n.sectionShareLinks),
              _ShareSection(mediaId: data.media.id, shares: data.shares),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preview(BuildContext context) {
    return GestureDetector(
      onTap: () => showFullscreenGallery(
        context,
        media: widget.media,
        initialIndex: _index,
        onIndexChanged: (index) => setState(() => _index = index),
      ),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ProtectedImage(
              url: _item.thumbnail?.url,
              blurhash: _item.blurhash,
              fit: BoxFit.contain,
            ),
            if (_item.type == MediaType.video)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 56,
                  color: Colors.white70,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ShareSection extends ConsumerStatefulWidget {
  final String mediaId;
  final List<MediaShare> shares;

  const _ShareSection({required this.mediaId, required this.shares});

  @override
  ConsumerState<_ShareSection> createState() => _ShareSectionState();
}

class _ShareSectionState extends ConsumerState<_ShareSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        final message = describeError(error, AppLocalizations.of(context));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showShareMenu(MediaShare share) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(AppLocalizations.of(context).shareCopyUrl),
              onTap: () {
                Navigator.of(sheetContext).pop();
                final session = ref.read(sessionProvider);
                if (session == null) return;

                Clipboard.setData(
                  ClipboardData(text: session.shareUrl(share.token).toString()),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context).shareLinkCopied),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                AppLocalizations.of(context).shareDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _run(
                  () => ref
                      .read(shareActionsProvider)
                      .deleteShare(widget.mediaId, share.token),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.shares.isEmpty)
          ListTile(
            title: Text(
              AppLocalizations.of(context).shareNone,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final share in widget.shares)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(share.token),
              onTap: _busy ? null : () => _showShareMenu(share),
            ),
        ListTile(
          leading: Icon(Icons.add, color: Theme.of(context).colorScheme.primary),
          title: Text(
            AppLocalizations.of(context).shareAdd,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          onTap: _busy
              ? null
              : () => _run(
                  () => ref.read(shareActionsProvider).addShare(widget.mediaId),
                ),
        ),
      ],
    );
  }
}
