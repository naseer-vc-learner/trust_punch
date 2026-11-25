// PLACEHOLDER CONFIGURATION.
//
// The project id is `demo-trustpunch`. The `demo-` prefix is meaningful: the
// Firebase SDKs and the Emulator Suite both treat it as a project that does not
// exist, so emulator mode works with no Firebase project, no login and no
// billing. Nothing here can reach a real backend.
//
// Replace this file before running against a real project.
//
// Generate the real file with:
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=<your-firebase-project-id>
//
// That command overwrites this file and also writes the native config
// (`android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`).
// The values below are structurally valid but point at nothing, so the app
// fails fast with a clear Firebase error rather than silently misbehaving.

// ignore_for_file: type=lint

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// A syntactically valid but non-functional key.
///
/// The native Firebase SDKs validate the *shape* of an API key at startup and
/// throw before any emulator redirect happens, so an obvious string like
/// "REPLACE_ME" crashes the app on Android. Real keys are 39 characters
/// beginning with `AIza`; this matches that and nothing else. It authenticates
/// against nothing — only the emulators accept it.
const placeholderApiKey = 'AIzaSyDEMOKEYFOREMULATORSONLY0000000000';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'TrustPunch is not configured for $defaultTargetPlatform. '
          'Run `flutterfire configure` to regenerate firebase_options.dart.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: placeholderApiKey,
    appId: '1:000000000000:android:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-trustpunch',
    storageBucket: 'demo-trustpunch.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: placeholderApiKey,
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-trustpunch',
    storageBucket: 'demo-trustpunch.appspot.com',
    iosBundleId: 'com.example.trustPunch',
  );

  static const FirebaseOptions macos = ios;

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: placeholderApiKey,
    appId: '1:000000000000:web:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-trustpunch',
    authDomain: 'demo-trustpunch.firebaseapp.com',
    storageBucket: 'demo-trustpunch.appspot.com',
  );
}
