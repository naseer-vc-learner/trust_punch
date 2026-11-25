import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.isFromMockProvider,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final bool isFromMockProvider;
}

class LocationDenied implements Exception {
  LocationDenied(this.message);
  final String message;
  @override
  String toString() => message;
}

class LocationService {
  /// Requests a fresh, high-accuracy fix.
  ///
  /// `forceAndroidLocationManager` is off so we get the fused provider, but the
  /// `isMocked` flag it carries is passed through untouched — the client does
  /// not act on it, the server does. Cached positions are not used: a stale fix
  /// is exactly what someone who drove away from the site would want.
  Future<LocationFix> currentFix({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationDenied('Location services are turned off.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw LocationDenied(
        'Location permission is required for on-site attendance.',
      );
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: timeout,
      ),
    );

    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      isFromMockProvider: position.isMocked,
    );
  }

  /// Live distance to a site, for the "you are 240 m away" readout.
  ///
  /// This is a display convenience only. The number that decides attendance is
  /// recomputed server-side from the coordinates in the submission.
  Stream<double> distanceToSite({
    required double siteLatitude,
    required double siteLongitude,
    int updateIntervalMeters = 10,
  }) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: updateIntervalMeters,
      ),
    ).map((p) => haversineMeters(
          p.latitude,
          p.longitude,
          siteLatitude,
          siteLongitude,
        ));
  }
}

const _earthRadiusMeters = 6371008.8;

double _radians(double degrees) => degrees * math.pi / 180;

/// Client-side mirror of `functions/src/lib/geo.ts`.
///
/// Kept identical so the distance the employee sees matches the one the server
/// will judge them by — a mismatch here reads as the app lying to them.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _radians(lat2 - lat1);
  final dLon = _radians(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_radians(lat1)) *
          math.cos(_radians(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * _earthRadiusMeters * math.asin(math.min(1, math.sqrt(a)));
}
