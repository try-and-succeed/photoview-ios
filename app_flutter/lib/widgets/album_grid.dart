import 'package:flutter/material.dart';

import '../api/models.dart';
import '../screens/album_screen.dart';
import 'protected_image.dart';

const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 180,
  crossAxisSpacing: 16,
  mainAxisSpacing: 16,
  childAspectRatio: 0.85,
);

class AlbumSliverGrid extends StatelessWidget {
  final List<AlbumItem> albums;

  const AlbumSliverGrid({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: _gridDelegate,
      itemCount: albums.length,
      itemBuilder: (context, index) => AlbumTile(album: albums[index]),
    );
  }
}

class AlbumGrid extends StatelessWidget {
  final List<AlbumItem> albums;

  const AlbumGrid({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: _gridDelegate,
      itemCount: albums.length,
      itemBuilder: (context, index) => AlbumTile(album: albums[index]),
    );
  }
}

class AlbumTile extends StatelessWidget {
  final AlbumItem album;

  const AlbumTile({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlbumScreen(albumId: album.id, title: album.title),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ProtectedImage(
                url: album.thumbnailUrl,
                blurhash: album.blurhash,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
