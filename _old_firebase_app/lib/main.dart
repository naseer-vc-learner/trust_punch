import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'src/app/app.dart';
import 'src/core/emulators.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final options = DefaultFirebaseOptions.currentPlatform;
  await Firebase.initializeApp(options: options);

  // Catch the one misconfiguration that otherwise surfaces as a baffling
  // "API key not valid" at sign-in: running against real Firebase while
  // firebase_options.dart still holds placeholders.
  //
  // Rendered as a screen rather than thrown. Throwing here aborts before
  // runApp, which leaves the device sitting on a blank splash with the
  // explanation buried in logs the person holding the phone cannot see.
  if (!useEmulator && options.apiKey == placeholderApiKey) {
    runApp(const _NotConfiguredApp());
    return;
  }

  if (useEmulator) {
    // Local-only mode. App Check is skipped because there is no attestation
    // service to issue tokens against a local server; the callables relax the
    // matching check when they detect FUNCTIONS_EMULATOR.
    //
    // Activating with the debug provider was tried here and reverted: it
    // still needs one round trip to the real App Check backend to exchange
    // the debug token (there is no local exchange), which fails the same way
    // DeviceCheck does against a placeholder project — and on-device that
    // failure was observed to also blank out the Authorization header on the
    // very next callable, turning every request into "Sign in required."
    // Leaving App Check untouched keeps the callables signed in correctly;
    // the background DeviceCheck noise it causes in the console is cosmetic.
    await connectToEmulators();
  } else {
    // App Check proves calls come from a genuine build of this app. Without it,
    // `submitCheckIn` could be driven from a script holding a stolen ID token,
    // and every device and liveness signal in the payload would be attacker-
    // chosen. Debug providers are used only in debug builds.
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );
  }

  runApp(const ProviderScope(child: TrustPunchApp()));
}

/// Shown instead of the app when it was launched without a usable backend.
///
/// The whole point is that it appears *on the device*: the person testing is
/// holding the phone, not reading the console.
class _NotConfiguredApp extends StatelessWidget {
  const _NotConfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF7F1D1D),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.settings_ethernet, color: Colors.white, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Not connected to a backend',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'firebase_options.dart still holds placeholder credentials, '
                  'and this is a release build, so the local-emulator fallback '
                  'is disabled. Every request would be rejected.',
                  style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 24),
                _Fix(
                  label: 'Run against local emulators',
                  command: './scripts/run-device.sh',
                ),
                const SizedBox(height: 12),
                _Fix(
                  label: 'Or connect a real Firebase project',
                  command: 'flutterfire configure --project=<id>',
                ),
                const Spacer(),
                const Text(
                  'Debug builds fall back to the local emulators automatically. '
                  'Only release builds reach this screen.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Fix extends StatelessWidget {
  const _Fix({required this.label, required this.command});

  final String label;
  final String command;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            command,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
