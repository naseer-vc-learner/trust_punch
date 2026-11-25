import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:safe_device/safe_device.dart';
import 'package:uuid/uuid.dart';

/// Identity and integrity of the handset itself.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.platform,
    required this.model,
  });

  final String deviceId;
  final String platform;
  final String model;
}

class DeviceIntegrity {
  const DeviceIntegrity({
    required this.isRooted,
    required this.isEmulator,
    required this.canMockLocation,
  });

  /// Any one of these is enough to stop trusting the signals this device sends.
  bool get isCompromised => isRooted || isEmulator || canMockLocation;

  final bool isRooted;
  final bool isEmulator;
  final bool canMockLocation;

  static const trusted =
      DeviceIntegrity(isRooted: false, isEmulator: false, canMockLocation: false);
}

class DeviceService {
  DeviceService({
    FlutterSecureStorage? storage,
    DeviceInfoPlugin? deviceInfo,
    LocalAuthentication? localAuth,
  })  : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            ),
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _localAuth = localAuth ?? LocalAuthentication();

  static const _deviceIdKey = 'trustpunch.device_id';

  final FlutterSecureStorage _storage;
  final DeviceInfoPlugin _deviceInfo;
  final LocalAuthentication _localAuth;

  DeviceIdentity? _cached;

  /// A stable per-install id held in the Keychain / EncryptedSharedPreferences.
  ///
  /// Deliberately not the hardware serial or IDFV: those are either unavailable
  /// or shared across apps. What matters is that it survives app restarts and
  /// cannot be read or forged by another app — reinstalling produces a new id,
  /// which correctly shows up server-side as an unregistered device.
  Future<DeviceIdentity> identity() async {
    if (_cached != null) return _cached!;

    var id = await _storage.read(key: _deviceIdKey);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: _deviceIdKey, value: id);
    }

    String platform = 'unknown';
    String model = 'unknown';
    if (Platform.isAndroid) {
      final info = await _deviceInfo.androidInfo;
      platform = 'android';
      model = '${info.manufacturer} ${info.model}';
    } else if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      platform = 'ios';
      model = info.utsname.machine;
    }

    return _cached = DeviceIdentity(deviceId: id, platform: platform, model: model);
  }

  /// Root / jailbreak / emulator posture.
  ///
  /// Fails closed on error: if we cannot establish that the device is clean,
  /// we treat it as compromised rather than assume the best.
  Future<DeviceIntegrity> integrity() async {
    try {
      final results = await Future.wait([
        SafeDevice.isJailBroken,
        SafeDevice.isRealDevice,
        SafeDevice.isMockLocation,
      ]);
      return DeviceIntegrity(
        isRooted: results[0],
        isEmulator: !results[1],
        canMockLocation: results[2],
      );
    } catch (_) {
      return const DeviceIntegrity(
        isRooted: true,
        isEmulator: false,
        canMockLocation: false,
      );
    }
  }

  /// Secondary factor only.
  ///
  /// Passing the device biometric proves the phone's owner unlocked it — it does
  /// NOT prove who is in front of the camera, which is why the server still runs
  /// its own face match. Treated as a convenience gate, never as identity.
  Future<bool> confirmLocalBiometric({String reason = 'Confirm it is you'}) async {
    try {
      if (!await _localAuth.isDeviceSupported()) return true;
      final available = await _localAuth.getAvailableBiometrics();
      if (available.isEmpty) return true;
      return await _localAuth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}
