import 'dart:async';

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
import '../l10n/error_messages.dart';
import '../state/auth.dart';
import '../state/library.dart';
import '../state/slideshow.dart';
import 'media_details_sheet.dart';

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

  /// Waiting out the current picture, when there is a slideshow running.
  Timer? _slideshow;

  bool _playing = false;

  /// Read afresh in `build`, so a change made in the settings takes hold on
  /// the next picture instead of only on the next slideshow.
  Duration _interval = const Duration(seconds: defaultSlideshowSeconds);

  /// Captured while the widget is alive. `ref` is not usable from `dispose`,
  /// and leaving the screen held awake after the gallery closes would be the
  /// worst of the failures available here.
  late final Future<void> Function(bool) _screenAwake = ref.read(
    screenAwakeProvider,
  );

  @override
  void dispose() {
    final wasPlaying = _playing;
    _slideshow?.cancel();
    if (wasPlaying) _keepScreenAwake(false);

    _controller.dispose();
    // Hidden controls also hid the system bars; the rest of the app expects
    // them back.
    if (!_controlsVisible) _showSystemBars(true);
    super.dispose();
  }

  void _keepScreenAwake(bool awake) {
    // A device that refuses is not a reason to refuse the slideshow.
    _screenAwake(awake).catchError((_) {});
  }

  /// The next photo after [from], wrapping around, or null when there is no
  /// other photo to go to.
  ///
  /// Videos are stepped over rather than shown for the interval: they play by
  /// themselves, and cutting one off after five seconds is worse than leaving
  /// it out of the slideshow.
  int? _nextPhoto(int from) {
    for (var step = 1; step <= widget.media.length; step++) {
      final candidate = (from + step) % widget.media.length;
      if (widget.media[candidate].type != MediaType.video) return candidate;
    }
    return null;
  }

  bool get _canPlay => widget.media.any((m) => m.type != MediaType.video);

  void _toggleSlideshow() {
    if (_playing) {
      _slideshow?.cancel();
      _slideshow = null;
      setState(() => _playing = false);
      _keepScreenAwake(false);
      return;
    }

    _keepScreenAwake(true);
    setState(() => _playing = true);
    _scheduleNext();
    // Nothing should lie over the pictures once they are showing themselves.
    _setControlsVisible(false);
  }

  /// One picture at a time rather than a periodic timer: the interval is read
  /// again for each, so changing the setting mid-slideshow is felt at once.
  void _scheduleNext() {
    _slideshow = Timer(_interval, () {
      if (!mounted || !_playing) return;
      _advance();
      _scheduleNext();
    });
  }

  void _advance() {
    final next = _nextPhoto(_index);
    if (next == null) return;

    _controller.animateToPage(
      next,
      duration: _pageTurn,
      curve: Curves.easeInOut,
    );
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

  /// Everything known about the photo on screen — camera data, the files it
  /// can be downloaded as, its public links — without leaving the gallery.
  void _showInfo() {
    showMediaDetails(
      context,
      media: widget.media,
      initialIndex: _index,
      showPreview: false,
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

    _interval = Duration(
      seconds:
          ref.watch(slideshowSecondsProvider).valueOrNull ??
          defaultSlideshowSeconds,
    );

    // A change made while the slideshow runs takes hold at once, rather than
    // after the picture on screen has waited out the old interval — which,
    // when the old one was a minute, feels like the setting did nothing.
    ref.listen(slideshowSecondsProvider, (_, next) {
      // Taken from the notification rather than from the field: this runs
      // before the rebuild that would have set it.
      final seconds = next.valueOrNull;
      if (seconds != null) _interval = Duration(seconds: seconds);

      if (!_playing) return;
      _slideshow?.cancel();
      _scheduleNext();
    });

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
                if (_canPlay)
                  IconButton(
                    icon: Icon(
                      _playing ? Icons.pause : Icons.slideshow_outlined,
                    ),
                    tooltip: _playing
                        ? AppLocalizations.of(context).slideshowStop
                        : AppLocalizations.of(context).slideshowStart,
                    onPressed: _toggleSlideshow,
                  ),
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

    // Inside the try along with the playing: opening the loopback server can
    // fail too — a session that ended under it, a media URL that does not
    // belong to the instance, a port that cannot be bound — and outside it
    // those left the spinner turning with nothing ever said.
    try {
      // Through the app's own server rather than straight at the instance:
      // the player does its own TLS against the system trust store, so a
      // certificate accepted in this app — a self-hosted authority, which is
      // the normal case here — is unknown to it and every video fails with
      // "Source error". See [MediaProxy]. The auth cookie is added upstream,
      // which is why none is set here.
      final address = await ref.read(mediaProxyProvider).serve(session, url);
      if (!mounted) return;

      final controller = VideoPlayerController.networkUrl(address);
      _videoController = controller;

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
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(() => _error = describeError(error, l10n));
      }
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
          describeError(error, AppLocalizations.of(context)),
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
