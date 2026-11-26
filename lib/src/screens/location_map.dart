import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/ui_text.dart';
import '../services/location_service.dart' show geofenceRadiusMeters;

/// One place to show on the map.
class MapPoint {
  const MapPoint(this.name, this.latitude, this.longitude);

  final String name;
  final double latitude;
  final double longitude;

  LatLng get latLng => LatLng(latitude, longitude);
}

/// Locations on an OpenStreetMap map, each with its check-in circle, so a
/// supervisor can see a site is where they think — and spot a typed
/// coordinate that put it in the sea.
///
/// Needs internet for the map tiles (the rest of the app does not). Tile
/// requests tell OpenStreetMap which area is being viewed; only supervisors
/// open this screen, and it shows sites, never workers.
class LocationMapScreen extends StatefulWidget {
  const LocationMapScreen({
    super.key,
    required this.title,
    required this.points,
    required this.lang,
  });

  final String title;
  final List<MapPoint> points;
  final String lang;

  @override
  State<LocationMapScreen> createState() => _LocationMapScreenState();
}

class _LocationMapScreenState extends State<LocationMapScreen> {
  bool _tilesFailing = false;

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    final scheme = Theme.of(context).colorScheme;
    final single = points.length == 1;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (_tilesFailing)
            MaterialBanner(
              content: Text(t(widget.lang, T.mapNeedsInternet)),
              leading: const Icon(Icons.wifi_off),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: points.isEmpty
                ? Center(child: Text(t(widget.lang, T.noLocationsYet)))
                : FlutterMap(
                    options: MapOptions(
                      initialCenter: points.first.latLng,
                      // Close enough that a 50 m circle is clearly visible.
                      initialZoom: 17,
                      initialCameraFit: single
                          ? null
                          : CameraFit.coordinates(
                              coordinates: [for (final p in points) p.latLng],
                              padding: const EdgeInsets.all(64),
                              maxZoom: 17,
                            ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        // OpenStreetMap's tile policy asks every app to
                        // identify itself.
                        userAgentPackageName: 'com.example.trust_punch',
                        errorTileCallback: (tile, error, stack) {
                          if (!_tilesFailing && mounted) {
                            setState(() => _tilesFailing = true);
                          }
                        },
                      ),
                      CircleLayer(
                        circles: [
                          for (final p in points)
                            CircleMarker(
                              point: p.latLng,
                              radius: geofenceRadiusMeters,
                              useRadiusInMeter: true,
                              color: scheme.primary.withValues(alpha: 0.18),
                              borderColor: scheme.primary,
                              borderStrokeWidth: 2,
                            ),
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          for (final p in points)
                            Marker(
                              point: p.latLng,
                              width: 160,
                              height: 56,
                              alignment: Alignment.topCenter,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: scheme.surface,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                  ),
                                  Icon(Icons.location_on,
                                      color: scheme.primary, size: 30),
                                ],
                              ),
                            ),
                        ],
                      ),
                      // Required by the OpenStreetMap licence.
                      const SimpleAttributionWidget(
                        source: Text('OpenStreetMap contributors'),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              t(widget.lang, T.mapCircleHelp)
                  .replaceAll('{m}', '${geofenceRadiusMeters.round()}'),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
