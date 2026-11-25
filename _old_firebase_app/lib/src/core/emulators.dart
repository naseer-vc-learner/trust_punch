import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import '../data/services/trustpunch_api.dart';
import 'emulator_host.g.dart';

/// Explicit opt-in via `--dart-define=USE_EMULATOR=true`.
const bool _explicitEmulatorFlag = bool.fromEnvironment('USE_EMULATOR');

/// Whether this build talks to the local Emulator Suite instead of Firebase.
///
/// True when the flag is set, **or** — in debug builds only — when
/// `firebase_options.dart` still holds placeholder credentials. That fallback
/// matters in practice: the IDE Run button passes no `--dart-define`, and
/// without it every such launch failed at the first request with an opaque
/// "API key not valid". A build with placeholder credentials cannot reach real
/// Firebase under any circumstances, so preferring the emulators loses nothing.
///
/// Release builds never take the fallback. `kReleaseMode` is a compile-time
/// constant, so the emulator branch is tree-shaken out of a release binary
/// entirely — an app that could be redirected to a local server at runtime
/// would be an app whose verification could be redirected to a local server.
bool get useEmulator =>
    _explicitEmulatorFlag ||
    (!kReleaseMode && DefaultFirebaseOptions.currentPlatform.apiKey == placeholderApiKey);

/// Explicit host override, e.g. `--dart-define=EMULATOR_HOST=192.168.68.185`.
///
/// Required on a **physical device**: a real phone is not the host machine, so
/// neither `localhost` nor the Android emulator's `10.0.2.2` alias reaches your
/// Mac. Pass the Mac's LAN IP and put both on the same Wi-Fi network.
const _hostOverride = String.fromEnvironment('EMULATOR_HOST');

/// Where the emulator suite is listening, from this device's point of view.
///
/// Defaults suit the simulators only:
///  - Android emulator reaches the host through the 10.0.2.2 alias
///  - iOS simulator and web share the host's loopback
String get emulatorHost {
  // 1. Explicit flag always wins.
  if (_hostOverride.isNotEmpty) return _hostOverride;

  // 2. The address scripts/emulators.sh last started on. This is what makes a
  //    flagless run work on a physical device, which cannot use the loopback
  //    or 10.0.2.2 defaults below.
  if (generatedEmulatorHost.isNotEmpty) return generatedEmulatorHost;

  // 3. Simulator defaults: the Android emulator reaches its host through the
  //    10.0.2.2 alias; the iOS simulator and web share the host's loopback.
  if (kIsWeb) return 'localhost';
  return Platform.isAndroid ? '10.0.2.2' : 'localhost';
}

/// Ports must match the `emulators` block in firebase.json.
const _authPort = 9099;
const _firestorePort = 8080;
const _functionsPort = 5001;
const _storagePort = 9199;

Future<void> connectToEmulators() async {
  final host = emulatorHost;

  await FirebaseAuth.instance.useAuthEmulator(host, _authPort);
  FirebaseFirestore.instance.useFirestoreEmulator(host, _firestorePort);
  FirebaseStorage.instance.useStorageEmulator(host, _storagePort);
  FirebaseFunctions.instanceFor(region: TrustPunchApi.defaultRegion)
      .useFunctionsEmulator(host, _functionsPort);

  debugPrint(
    '⚠️  TrustPunch is running against LOCAL EMULATORS at $host. '
    'No data reaches any Firebase project.',
  );
}
