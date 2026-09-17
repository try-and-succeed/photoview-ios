import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../state/library.dart';
import '../widgets/scrollable_view.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';

class ClusterScreen extends ConsumerStatefulWidget {
  final List<String> mediaIds;
  final LatLng location;

  const ClusterScreen({
    super.key,
    required this.mediaIds,
    required this.location,
  });

  @override
  ConsumerState<ClusterScreen> createState() => _ClusterScreenState();
}

class _ClusterScreenState extends ConsumerState<ClusterScreen> {
  String? _locationName;

  @override
  void initState() {
    super.initState();
    _resolveLocationName();
  }

  /// Reverse geocoding is a nicety — the screen keeps its generic title when
  /// the platform has no geocoder or the lookup fails.
  Future<void> _resolveLocationName() async {
    try {
      final places = await Geocoding().placemarkFromCoordinates(
        widget.location.latitude,
        widget.location.longitude,
      );

      final place = places.firstOrNull;
      final locality = place?.locality;
      final country = place?.country;

      if (!mounted || locality == null || country == null) return;
      if (locality.isEmpty || country.isEmpty) return;

      setState(() => _locationName = '$locality, $country');
    } catch (_) {
      // Keep the fallback title.
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.mediaIds.join(',');
    final media = ref.watch(clusterMediaProvider(key));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _locationName ?? AppLocalizations.of(context).clusterTitleFallback,
        ),
      ),
      body: media.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage.forError(
          error,
          onRetry: () => ref.invalidate(clusterMediaProvider(key)),
        ),
        data: (data) => data.isEmpty
            ? EmptyMessage(message: AppLocalizations.of(context).clusterEmpty)
            : ScrollableView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    sliver: MediaSliverGrid(media: data),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
      ),
    );
  }
}
