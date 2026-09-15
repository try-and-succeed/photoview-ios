import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../api/models.dart';
import '../state/library.dart';
import '../widgets/async_states.dart';
import '../widgets/protected_image.dart';
import 'cluster_screen.dart';

/// Roughly how many logical pixels apart two pins must be to stay separate.
const _clusterPixelRadius = 70.0;
const _tileSize = 256.0;

class MarkerCluster {
  final List<PlacesMarker> markers;
  final LatLng center;

  const MarkerCluster({required this.markers, required this.center});

  bool get isSingle => markers.length == 1;
}

/// Buckets pins into a grid whose cell size shrinks as the map zooms in, so
/// dense areas collapse into one pin until the user zooms far enough.
List<MarkerCluster> clusterMarkers(List<PlacesMarker> markers, double zoom) {
  if (markers.isEmpty) return const [];

  final worldPixels = _tileSize * pow(2, zoom);
  final degreesPerCell = 360 / worldPixels * _clusterPixelRadius;

  final cells = <String, List<PlacesMarker>>{};
  for (final marker in markers) {
    final x = (marker.longitude / degreesPerCell).floor();
    final y = (marker.latitude / degreesPerCell).floor();
    cells.putIfAbsent('$x:$y', () => []).add(marker);
  }

  return cells.values.map((group) {
    final latitude =
        group.map((m) => m.latitude).reduce((a, b) => a + b) / group.length;
    final longitude =
        group.map((m) => m.longitude).reduce((a, b) => a + b) / group.length;

    return MarkerCluster(markers: group, center: LatLng(latitude, longitude));
  }).toList();
}

class PlacesScreen extends ConsumerStatefulWidget {
  const PlacesScreen({super.key});

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  final _mapController = MapController();
  double _zoom = 2;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _openCluster(MarkerCluster cluster) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClusterScreen(
          mediaIds: cluster.markers.map((m) => m.mediaId).toList(),
          location: cluster.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final markers = ref.watch(placesMarkersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: markers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage.forError(
          error,
          onRetry: () => ref.invalidate(placesMarkersProvider),
        ),
        data: (data) {
          if (data.isEmpty) {
            return const EmptyMessage(
              message: 'None of your media has location data',
              icon: Icons.map_outlined,
            );
          }

          final clusters = clusterMarkers(data, _zoom);

          return FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialCenter(data),
              initialZoom: _zoom,
              onPositionChanged: (camera, _) {
                if ((camera.zoom - _zoom).abs() > 0.25) {
                  setState(() => _zoom = camera.zoom);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.github.photoview.photoview',
              ),
              MarkerLayer(
                markers: [
                  for (final cluster in clusters)
                    Marker(
                      point: cluster.center,
                      width: 64,
                      height: 64,
                      child: _ClusterPin(
                        cluster: cluster,
                        onTap: () => _openCluster(cluster),
                      ),
                    ),
                ],
              ),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  LatLng _initialCenter(List<PlacesMarker> markers) {
    final latitude =
        markers.map((m) => m.latitude).reduce((a, b) => a + b) / markers.length;
    final longitude =
        markers.map((m) => m.longitude).reduce((a, b) => a + b) /
        markers.length;

    return LatLng(latitude, longitude);
  }
}

class _ClusterPin extends StatelessWidget {
  final MarkerCluster cluster;
  final VoidCallback onTap;

  const _ClusterPin({required this.cluster, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = cluster.markers.first;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(blurRadius: 6, color: Colors.black38),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 56,
                child: ProtectedImage(url: first.thumbnail.url),
              ),
            ),
          ),
          if (!cluster.isSingle)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  '${cluster.markers.length}',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
