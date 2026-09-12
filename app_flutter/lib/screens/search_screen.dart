import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';

void showPhotoviewSearch(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Waits for a pause in typing so each keystroke does not hit the server.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search albums and media',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (value) => setState(() => _query = value.trim()),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: _query.isEmpty
          ? const EmptyMessage(
              message: 'Type to search your library',
              icon: Icons.search,
            )
          : _Results(query: _query),
    );
  }
}

class _Results extends ConsumerWidget {
  final String query;

  const _Results({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchProvider(query));

    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorMessage(
        message: '$error',
        onRetry: () => ref.invalidate(searchProvider(query)),
      ),
      data: (data) {
        if (data.albums.isEmpty && data.media.isEmpty) {
          return const EmptyMessage(
            message: 'No results',
            icon: Icons.search_off,
          );
        }

        return CustomScrollView(
          slivers: [
            if (data.albums.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _SectionTitle('Albums')),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: AlbumSliverGrid(albums: data.albums),
              ),
            ],
            if (data.media.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _SectionTitle('Media')),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                sliver: MediaSliverGrid(media: data.media),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
