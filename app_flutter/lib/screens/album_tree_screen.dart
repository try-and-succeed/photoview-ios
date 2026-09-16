import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/album_tree.dart';
import '../widgets/async_states.dart';
import 'album_screen.dart';

void showAlbumTree(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const AlbumTreeScreen()));
}

/// The whole album hierarchy, one level fetched at a time.
///
/// Complements rather than replaces the per-album navigation: this is for
/// finding something several levels down without walking there.
class AlbumTreeScreen extends ConsumerStatefulWidget {
  const AlbumTreeScreen({super.key});

  @override
  ConsumerState<AlbumTreeScreen> createState() => _AlbumTreeScreenState();
}

class _AlbumTreeScreenState extends ConsumerState<AlbumTreeScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  /// What the user is filtering by, right now.
  ///
  /// Deliberately screen state rather than provider state: the tree itself is
  /// worth keeping between visits, the half-typed search is not.
  String _filter = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Waits for a pause in typing before re-flattening the tree.
  ///
  /// Filtering shows every loaded branch open, so each keystroke rebuilds a
  /// row for every album fetched so far — on a library of a couple of thousand
  /// that is real work to repeat six times a second. Same pause the search
  /// field uses.
  void _onFilterChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _filter = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tree = ref.watch(albumTreeProvider);
    final notifier = ref.read(albumTreeProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context).albumTreeFilterHint,
            border: InputBorder.none,
          ),
          autocorrect: false,
          onChanged: _onFilterChanged,
        ),
        actions: [
          if (_filter.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _debounce?.cancel();
                _controller.clear();
                setState(() => _filter = '');
              },
            ),
        ],
      ),
      body: _body(tree, notifier),
    );
  }

  Widget _body(AlbumTreeState tree, AlbumTreeNotifier notifier) {
    // Roots get their own loading and error state. A branch that fails must
    // not read as the whole tree being unavailable, and the other way round.
    if (tree.isLoadingRoots) {
      return const Center(child: CircularProgressIndicator());
    }

    final rootsError = tree.rootsError;
    if (rootsError != null) {
      return ErrorMessage.forError(rootsError, onRetry: notifier.loadRoots);
    }

    final rows = tree.rowsFor(_filter);
    if (rows.isEmpty) {
      return EmptyMessage(
        message: _filter.isEmpty
            ? AppLocalizations.of(context).albumTreeEmpty
            : AppLocalizations.of(context).albumTreeNoMatch,
        icon: _filter.isEmpty
            ? Icons.photo_album_outlined
            : Icons.search_off,
      );
    }

    // While filtering, every loaded branch is shown open regardless of what
    // the user expanded, so the arrow would say "Collapse" while quietly
    // marking the branch as expanded — and it would stay open once the filter
    // was cleared. No toggle is offered instead of one that lies.
    final canToggle = _filter.isEmpty;

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => _AlbumTreeTile(
        row: rows[index],
        onToggle: canToggle
            ? () => notifier.toggle(rows[index].album.id)
            : null,
        onRetry: () => notifier.retry(rows[index].album.id),
      ),
    );
  }
}

class _AlbumTreeTile extends StatelessWidget {
  final AlbumTreeRow row;

  /// Null while a filter is active, when expanding means nothing.
  final VoidCallback? onToggle;
  final VoidCallback onRetry;

  const _AlbumTreeTile({
    required this.row,
    required this.onToggle,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final album = row.album;

    return ListTile(
      contentPadding: EdgeInsets.only(left: 16 + row.depth * 20.0, right: 8),
      leading: _leading(theme, l10n),
      title: Text(
        album.title.isEmpty ? l10n.untitledAlbum : album.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: row.error == null
          ? null
          : Text(
              l10n.albumTreeSubAlbumsFailed,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
      trailing: row.error != null
          ? IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.actionRetry,
              onPressed: onRetry,
            )
          : null,
      // Tapping the row opens the album; only the arrow expands it. Otherwise
      // an album that is both a container and full of photos has no way to be
      // opened.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AlbumScreen(albumId: album.id, title: album.title),
        ),
      ),
    );
  }

  Widget _leading(ThemeData theme, AppLocalizations l10n) {
    if (row.isLoading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // Null means nobody has asked yet: no arrow, rather than one that might
    // reveal nothing.
    if (row.hasChildren != true) {
      return Icon(
        Icons.photo_album_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    final icon = Icon(
      row.isExpanded ? Icons.expand_more : Icons.chevron_right,
    );

    // Filtering: the arrow still shows where the branch sits, but it is not a
    // button, because there is nothing meaningful for it to do.
    if (onToggle == null) {
      return IconTheme.merge(
        data: IconThemeData(color: theme.colorScheme.onSurfaceVariant),
        child: icon,
      );
    }

    return IconButton(
      icon: icon,
      tooltip: row.isExpanded ? l10n.albumTreeCollapse : l10n.albumTreeExpand,
      onPressed: onToggle,
    );
  }
}
