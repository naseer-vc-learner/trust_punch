import 'package:flutter/foundation.dart';
import 'package:safe_device/safe_device.dart';

/// Checks that the phone itself can be believed.
///
/// Both of these defeat the geofence completely if ignored: a fake-GPS app
/// puts you at the site from home, and a jailbroken phone can run one without
/// any of the usual restrictions. An attendance record is only worth as much
/// as the device that produced it.
class IntegrityService {
  bool? _cached;

  Future<bool> isCompromised() async {
    if (_cached != null) return _cached!;
    try {
      final jailbroken = await SafeDevice.isJailBroken;
      final realDevice = await SafeDevice.isRealDevice;
      _cached = jailbroken || !realDevice;
    } catch (e) {
      // A detection library that fails should not lock everyone out.
      debugPrint('Integrity check failed: $e');
      _cached = false;
    }
    return _cached!;
  }
}
