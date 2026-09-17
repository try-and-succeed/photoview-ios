import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/album_grid.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';
import '../widgets/search_results.dart';

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
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context).searchHint,
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
          ? EmptyMessage(
              message: AppLocalizations.of(context).searchPrompt,
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
      error: (error, _) => ErrorMessage.forError(
        error,
        onRetry: () => ref.invalidate(searchProvider(query)),
      ),
      data: (data) {
        if (data.albums.isEmpty && data.media.isEmpty) {
          return EmptyMessage(
            message: AppLocalizations.of(context).searchNoResults,
            icon: Icons.search_off,
          );
        }

        final albums = planSearchSection(data.albums.length);
        final media = planSearchSection(data.media.length);

        return ScrollableView(
          slivers: [
            if (albums.shown > 0) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  AppLocalizations.of(context).navAlbums,
                  count: data.albums.length,
                ),
              ),
              if (albums.layout == SearchResultLayout.grid)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: AlbumSliverGrid(
                    albums: data.albums.take(albums.shown).toList(),
                  ),
                )
              else
                AlbumResultList(
                  albums: data.albums.take(albums.shown).toList(),
                ),
              if (albums.hasHidden)
                SliverToBoxAdapter(
                  child: HiddenResultsNote(hidden: albums.hidden),
                ),
            ],
            if (media.shown > 0) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  AppLocalizations.of(context).searchMedia,
                  count: data.media.length,
                ),
              ),
              if (media.layout == SearchResultLayout.grid)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  sliver: MediaSliverGrid(
                    media: data.media.take(media.shown).toList(),
                  ),
                )
              else
                MediaResultList(
                  media: data.media.take(media.shown).toList(),
                ),
              if (media.hasHidden)
                SliverToBoxAdapter(
                  child: HiddenResultsNote(hidden: media.hidden),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// The heading of a result section, with the count once the list is too long
/// to take in at a glance, written with the app language's digit grouping.
@visibleForTesting
String searchSectionLabel(String title, int count) =>
    count > compactSearchThreshold
        ? '$title · ${NumberFormat.decimalPattern().format(count)}'
        : title;

class _SectionTitle extends StatelessWidget {
  final String title;

  /// Shown alongside the heading once the list is long enough that the user
  /// cannot count it at a glance.
  final int count;

  const _SectionTitle(this.title, {required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = searchSectionLabel(title, count);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(label, style: theme.textTheme.titleSmall),
    );
  }
}
