import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../state/search_limit.dart';
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

  /// Set once the user asks to see everything, and cleared as soon as the
  /// words change: the next search starts small again, as the first one did.
  bool _showAll = false;

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
      if (mounted) _setQuery(value);
    });
  }

  void _setQuery(String value) {
    // The timer from the last keystroke is still armed when the user submits
    // instead of waiting for it. Left running it fires a moment later with
    // the same words — and clears "show all" again, so a list the user has
    // just asked to see in full snaps back to the first few.
    _debounce?.cancel();
    _debounce = null;

    setState(() {
      _query = value.trim();
      _showAll = false;
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
          onSubmitted: _setQuery,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _setQuery('');
              },
            ),
        ],
      ),
      body: _query.isEmpty
          ? EmptyMessage(
              message: AppLocalizations.of(context).searchPrompt,
              icon: Icons.search,
            )
          : _Results(
              query: _query,
              showAll: _showAll,
              onShowAll: () => setState(() => _showAll = true),
            ),
    );
  }
}

class _Results extends ConsumerWidget {
  final String query;

  /// Whether the user asked for everything rather than the first few.
  final bool showAll;

  final VoidCallback onShowAll;

  const _Results({
    required this.query,
    required this.showAll,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // "Everything" means everything this screen can put up — a section stops
    // at [maxRenderedSearchResults] however many come back. One more than
    // that is asked for, so a section that hit the ceiling can say so.
    //
    // Measured against a real library: asking the server for no limit at all
    // brought 2.7 MB and four seconds for one word, and 6.7 MB for another,
    // to fill a list that stops at five hundred.
    final request = (
      query: query,
      limit: showAll ? maxRenderedSearchResults + 1 : null,
    );
    final results = ref.watch(searchProvider(request));

    // What the server was told to send without "show all": the user's
    // setting, or the server's own default when they have set none.
    final configured =
        ref.watch(searchLimitProvider).valueOrNull?.value ??
        defaultSearchResultLimit;

    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorMessage.forError(
        error,
        onRetry: () => ref.invalidate(searchProvider(request)),
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

        // A section that came back exactly as long as the limit is a section
        // that was cut off — there is no way to tell "ten hits" from "ten of
        // many" apart from asking for more.
        final offerAll =
            !showAll &&
            configured > 0 &&
            (data.albums.length >= configured || data.media.length >= configured);

        return ScrollableView(
          slivers: [
            if (offerAll)
              SliverToBoxAdapter(child: _ShowAllResults(onTap: onShowAll)),
            if (albums.shown > 0) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  AppLocalizations.of(context).navAlbums,
                  count: data.albums.length,
                  atCeiling: albums.atCeiling,
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
                  child: HiddenResultsNote(
                    hidden: albums.hidden,
                    atCeiling: albums.atCeiling,
                  ),
                ),
            ],
            if (media.shown > 0) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  AppLocalizations.of(context).searchMedia,
                  count: data.media.length,
                  atCeiling: media.atCeiling,
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
                  child: HiddenResultsNote(
                    hidden: media.hidden,
                    atCeiling: media.atCeiling,
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// The entry the web client has above its results, in the same place.
///
/// Without it, seeing past the first few hits meant going into Settings and
/// raising a limit — for one search, and then lowering it again.
class _ShowAllResults extends StatelessWidget {
  final VoidCallback onTap;

  const _ShowAllResults({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: Icon(Icons.manage_search, color: theme.colorScheme.primary),
      title: Text(
        AppLocalizations.of(context).searchShowAll,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// The heading of a result section, with the count once the list is too long
/// to take in at a glance, written with the app language's digit grouping.
@visibleForTesting
String searchSectionLabel(String title, int count, {bool atCeiling = false}) {
  if (count <= compactSearchThreshold) return title;

  // At the ceiling the total is unknown — one more than can be shown was
  // asked for, and nothing past that was counted — so the number shown is
  // what is on screen, marked as "and more".
  final shown = atCeiling ? maxRenderedSearchResults : count;
  final written = NumberFormat.decimalPattern().format(shown);

  return atCeiling ? '$title · $written+' : '$title · $written';
}

class _SectionTitle extends StatelessWidget {
  final String title;

  /// Shown alongside the heading once the list is long enough that the user
  /// cannot count it at a glance.
  final int count;

  final bool atCeiling;

  const _SectionTitle(
    this.title, {
    required this.count,
    this.atCeiling = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = searchSectionLabel(title, count, atCeiling: atCeiling);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(label, style: theme.textTheme.titleSmall),
    );
  }
}
