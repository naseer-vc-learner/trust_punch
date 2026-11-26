import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../models/attendance.dart';

/// How close to a site you must be to punch there.
const double geofenceRadiusMeters = 50;

/// The vaguest fix accepted, as the OS's own error radius.
///
/// A fix good to ±200 m could put someone inside a 50 m geofence while they
/// stand outside it, so anything coarser than this is refused rather than
/// trusted. Indoors or among tall buildings this can refuse an honest worker;
/// stepping into the open usually fixes it within seconds.
const double maxFixAccuracyMeters = 30;

class SiteDistance {
  const SiteDistance(this.site, this.meters);
  final Site site;
  final double meters;

  bool get inRange => meters <= geofenceRadiusMeters;
}

/// Every site ranked by how far away it is, nearest first.
///
/// Ranking rather than returning the first hit is what makes a day across
/// several sites work: the app decides where you are instead of asking.
List<SiteDistance> rankSites(LocationFix fix, List<Site> sites) {
  final ranked = sites
      .map((site) => SiteDistance(
            site,
            haversineMeters(
              fix.latitude,
              fix.longitude,
              site.latitude,
              site.longitude,
            ),
          ))
      .toList()
    ..sort((a, b) => a.meters.compareTo(b.meters));
  return ranked;
}

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.isMocked,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;

  /// Precise enough to judge a geofence. A negative accuracy means the OS
  /// could not estimate it at all, which is treated as not precise.
  bool get isPrecise =>
      accuracyMeters >= 0 && accuracyMeters <= maxFixAccuracyMeters;

  /// Reported by the OS when the position came from a fake-GPS app.
  final bool isMocked;
}

class MockedLocation implements Exception {
  @override
  String toString() => 'This location is not real.';
}

class LocationDenied implements Exception {
  LocationDenied(this.message);
  final String message;
  @override
  String toString() => message;
}

class LocationService {
  /// A fresh high-accuracy fix. Cached positions are refused on purpose: a
  /// stale fix is exactly what someone who left the site would benefit from.
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
      throw LocationDenied('Location permission is required to punch.');
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
      isMocked: position.isMocked,
    );
  }
}

/// Coordinates typed by a supervisor, range-checked. Null when either is not
/// a finite number, or latitude is outside ±90 or longitude outside ±180.
(double, double)? parseLatLng(String latitude, String longitude) {
  final lat = double.tryParse(latitude.trim());
  final lng = double.tryParse(longitude.trim());
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) {
    return null;
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return (lat, lng);
}

/// Splits a pair pasted from a map app, such as "25.2048, 55.2708", into its
/// two halves. Null when the text is not exactly two parts.
(String, String)? splitLatLngPair(String text) {
  final parts =
      text.split(RegExp(r'[,\s]+')).where((p) => p.isNotEmpty).toList();
  return parts.length == 2 ? (parts[0], parts[1]) : null;
}

const _earthRadiusMeters = 6371008.8;

double _radians(double degrees) => degrees * math.pi / 180;

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
