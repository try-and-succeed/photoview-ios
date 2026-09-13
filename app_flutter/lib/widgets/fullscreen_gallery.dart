import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

import '../api/models.dart';
import '../api/session.dart';
import '../state/auth.dart';
import '../state/library.dart';

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

class _FullscreenGalleryState extends ConsumerState<FullscreenGallery> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.media.length}',
          style: const TextStyle(fontSize: 15),
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

                final url = item.thumbnail?.url;
                if (url == null || url.isEmpty) {
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
                  );
                }

                return PhotoViewGalleryPageOptions(
                  imageProvider: CachedNetworkImageProvider(
                    session.resolve(url).toString(),
                    cacheKey: session.cacheKeyFor(url),
                    headers: session.headers,
                  ),
                  heroAttributes: PhotoViewHeroAttributes(tag: item.id),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 4,
                );
              },
            ),
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
          'Could not play video: $_error',
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
          return const Center(
            child: Text(
              'No playable video rendition available',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) => _setup(session, url));
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
