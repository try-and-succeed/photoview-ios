import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

import '../api/models.dart';
import '../api/session.dart';
import '../l10n/app_localizations.dart';
import '../state/auth.dart';
import '../state/library.dart';
import '../util/formatting.dart';
import 'exif_table.dart';

void showFullscreenGallery(
  BuildContext context, {
  required List<MediaItem> media,
  required int initialIndex,
  void Function(int index)? onIndexChanged,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FullscreenGallery(
        media: media,
        initialIndex: initialIndex,
        onIndexChanged: onIndexChanged,
      ),
    ),
  );
}

class FullscreenGallery extends ConsumerStatefulWidget {
  final List<MediaItem> media;
  final int initialIndex;
  final void Function(int index)? onIndexChanged;

  const FullscreenGallery({
    super.key,
    required this.media,
    required this.initialIndex,
    this.onIndexChanged,
  });

  @override
  ConsumerState<FullscreenGallery> createState() => _FullscreenGalleryState();
}

/// What a key does in the gallery.
enum GalleryAction { previous, next, close, info }

/// The gallery's keys, for tablets and phones with a keyboard attached.
@visibleForTesting
GalleryAction? galleryActionFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp) {
    return GalleryAction.previous;
  }
  if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.pageDown) {
    return GalleryAction.next;
  }
  if (key == LogicalKeyboardKey.escape) return GalleryAction.close;
  if (key == LogicalKeyboardKey.keyI) return GalleryAction.info;
  return null;
}

const _pageTurn = Duration(milliseconds: 250);

class _FullscreenGalleryState extends ConsumerState<FullscreenGallery> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// Whether the bar with the position and actions is showing. A tap on a
  /// photo toggles it, so nothing lies over the picture while looking at it.
  bool _controlsVisible = true;

  @override
  void dispose() {
    _controller.dispose();
    // Hidden controls also hid the system bars; the rest of the app expects
    // them back.
    if (!_controlsVisible) _showSystemBars(true);
    super.dispose();
  }

  static void _showSystemBars(bool visible) {
    SystemChrome.setEnabledSystemUIMode(
      visible ? SystemUiMode.manual : SystemUiMode.immersiveSticky,
      overlays: visible ? SystemUiOverlay.values : null,
    );
  }

  void _setControlsVisible(bool visible) {
    if (visible == _controlsVisible) return;
    setState(() => _controlsVisible = visible);
    _showSystemBars(visible);
  }

  void _toggleControls() => _setControlsVisible(!_controlsVisible);

  /// The camera data of the photo on screen, without leaving the gallery.
  void _showInfo() {
    final item = widget.media[_index];

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _InfoPanel(item: item),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    switch (galleryActionFor(event.logicalKey)) {
      case GalleryAction.previous:
        _controller.previousPage(duration: _pageTurn, curve: Curves.easeOut);
        return KeyEventResult.handled;
      case GalleryAction.next:
        _controller.nextPage(duration: _pageTurn, curve: Curves.easeOut);
        return KeyEventResult.handled;
      case GalleryAction.close:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      case GalleryAction.info:
        _showInfo();
        return KeyEventResult.handled;
      case null:
        // Any other key — Tab above all — brings the controls back, so focus
        // moves onto buttons that can be seen. Hidden controls stay in the
        // tree and reachable; they are only faded out, never removed.
        _setControlsVisible(true);
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: _scaffold(session),
    );
  }

  Widget _scaffold(Session? session) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: AppBar(
              backgroundColor: Colors.black38,
              foregroundColor: Colors.white,
              title: Text(
                '${_index + 1} / ${widget.media.length}',
                style: const TextStyle(fontSize: 15),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  tooltip: AppLocalizations.of(context).galleryInfo,
                  onPressed: _showInfo,
                ),
              ],
            ),
          ),
        ),
      ),
      body: session == null
          ? const SizedBox.shrink()
          : PhotoViewGallery.builder(
              pageController: _controller,
              itemCount: widget.media.length,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              onPageChanged: (index) {
                setState(() => _index = index);
                widget.onIndexChanged?.call(index);
              },
              builder: (context, index) {
                final item = widget.media[index];

                if (item.type == MediaType.video) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: _VideoPage(mediaId: item.id),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.contained,
                  );
                }

                final thumbnail = item.thumbnail;
                if (thumbnail == null ||
                    thumbnail.url.isEmpty ||
                    thumbnail.width <= 0 ||
                    thumbnail.height <= 0) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white38,
                        size: 48,
                      ),
                    ),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.contained,
                    onTapUp: (_, _, _) => _toggleControls(),
                  );
                }

                // A custom child rather than an image provider, so the page
                // can show the thumbnail at once and fade the full image in
                // over it. Only the aspect ratio of childSize matters: zoom
                // scales the canvas, and the full image is drawn from its own
                // pixels at whatever scale that is.
                return PhotoViewGalleryPageOptions.customChild(
                  child: _PhotoPage(item: item, session: session),
                  childSize: Size(
                    thumbnail.width.toDouble(),
                    thumbnail.height.toDouble(),
                  ),
                  heroAttributes: PhotoViewHeroAttributes(tag: item.id),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 4,
                  onTapUp: (_, _, _) => _toggleControls(),
                );
              },
            ),
    );
  }
}

/// Title and camera data of one photo, for the gallery's info button.
class _InfoPanel extends ConsumerWidget {
  final MediaItem item;

  const _InfoPanel({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final details = ref.watch(mediaDetailsProvider(item.id));

    Widget message(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: color ?? theme.colorScheme.onSurfaceVariant),
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              details.valueOrNull?.title ?? item.title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          details.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => message(
              l10n.mediaDetailsFailed('$error'),
              color: theme.colorScheme.error,
            ),
            data: (data) {
              final exif = data.exif;
              if (exif == null || exifRows(exif, l10n).isEmpty) {
                return message(l10n.galleryNoCameraData);
              }
              return ExifTable(exif: exif);
            },
          ),
        ],
      ),
    );
  }
}

/// Longest side, in pixels, a full image is decoded at.
///
/// The full rendition of a JPEG is the original, and a 24-megapixel original
/// decodes to around 96 MB; the gallery keeps the neighbouring pages alive as
/// well. 4096 is still more than twice a phone screen's long side, so zooming
/// in stays sharp well past the thumbnail.
const fullImageDecodeLimit = 4096;

/// The renditions a gallery page layers, bottom to top.
///
/// The thumbnail is shown at once; the full image, once the details that name
/// it have arrived, is faded in over it. No full layer when the details are
/// not in yet, have none, or name the thumbnail itself.
@visibleForTesting
List<Thumbnail> galleryLayers(MediaItem item, MediaDetails? details) {
  final thumbnail = item.thumbnail;
  final full = details?.highRes;

  return [
    ?thumbnail,
    if (full != null && full.url.isNotEmpty && full.url != thumbnail?.url)
      full,
  ];
}

/// One photo: the thumbnail straight away, the full image over it when ready.
///
/// The full image comes from the details query, asked per page as it is
/// shown, rather than from the grid queries — those fetch hundreds of items
/// at once, and only the few actually opened need it.
class _PhotoPage extends ConsumerWidget {
  final MediaItem item;
  final Session session;

  const _PhotoPage({required this.item, required this.session});

  ImageProvider _provider(Thumbnail rendition) => CachedNetworkImageProvider(
    session.resolve(rendition.url).toString(),
    cacheKey: session.cacheKeyFor(rendition.url),
    headers: session.headers,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(mediaDetailsProvider(item.id)).valueOrNull;
    final layers = galleryLayers(item, details);

    return Stack(
      fit: StackFit.expand,
      children: [
        for (final (index, rendition) in layers.indexed)
          if (index == 0)
            Image(
              image: _provider(rendition),
              fit: BoxFit.contain,
              gaplessPlayback: true,
            )
          else
            Image(
              image: ResizeImage(
                _provider(rendition),
                width: fullImageDecodeLimit,
                height: fullImageDecodeLimit,
                policy: ResizeImagePolicy.fit,
                allowUpscaling: false,
              ),
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, synchronous) =>
                  AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: synchronous
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    child: child,
                  ),
              // A full image that fails to load leaves the thumbnail showing,
              // which is still a picture of the right thing.
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
      ],
    );
  }
}

/// Videos are streamed from the `videoWeb` rendition, which is only present on
/// the details query, so the page resolves it on demand.
class _VideoPage extends ConsumerStatefulWidget {
  final String mediaId;

  const _VideoPage({required this.mediaId});

  @override
  ConsumerState<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<_VideoPage> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _error;

  Future<void> _setup(Session session, String url) async {
    if (_videoController != null) return;

    final controller = VideoPlayerController.networkUrl(
      session.resolve(url),
      httpHeaders: session.headers,
    );
    _videoController = controller;

    try {
      await controller.initialize();
      if (!mounted) return;

      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: controller,
          autoPlay: true,
          looping: false,
          aspectRatio: controller.value.aspectRatio,
        );
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final details = ref.watch(mediaDetailsProvider(widget.mediaId));

    if (_error != null) {
      return Center(
        child: Text(
          AppLocalizations.of(context).videoPlayFailed(_error!),
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      );
    }

    final chewie = _chewieController;
    if (chewie != null) return Chewie(controller: chewie);

    return details.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          '$error',
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
      data: (data) {
        final url = data.videoWebUrl;
        if (url == null || session == null) {
          return Center(
            child: Text(
              AppLocalizations.of(context).videoNoRendition,
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) => _setup(session, url));
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
