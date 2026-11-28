import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;

import 'main.dart' show TrustPunchApp;
import 'src/connected/device_token.dart';
import 'src/connected/punch_sync.dart';
import 'src/connected/server_api.dart';
import 'src/connected/server_panel.dart';
import 'src/services/face_recognizer.dart';
import 'src/services/punch_guards.dart';
import 'src/services/speech_service.dart';
import 'src/services/supervisor_lock.dart';
import 'src/store/attendance_store.dart';

/// "TrustPunch Connected": the same app as the demo, plus sending punches
/// to the local server. A separate app on the phone (its own id and data),
/// so the offline demo is never touched:
///
///     flutter run --flavor connected -t lib/main_connected.dart \
///       --dart-define=API_BASE_URL=https://<mac-ip>:8443 \
///       --dart-define=API_DEV_CA=$(base64 -i backend/certs/dev-ca.pem)
///
/// lib/main.dart (the demo) never imports anything under src/connected/.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // This entry point inside the demo app would send the demo app's data to
  // a server. Refuse, rather than mix the two.
  if (appFlavor != 'connected') {
    runApp(const _WrongFlavor());
    return;
  }

  final store = await AttendanceStore.load();
  final lock = await SupervisorLock.load();
  final api = ServerApi.fromEnvironment();
  final sync = api == null
      ? null
      : PunchSync(store: store, api: api, tokens: SecureTokenStore());
  await sync?.start();
  // Before a punch, ask the server whether this worker is on the clock on
  // another phone (gate phone vs. their own). The demo app never sets this.
  if (sync != null) PunchGuards.checkedInElsewhere = sync.checkedInElsewhere;

  runApp(TrustPunchApp(
    store: store,
    lock: lock,
    recognizer: FaceRecognizer(),
    speech: SpeechService(),
    pickerFooter: ServerPanel(sync: sync, store: store, lock: lock),
  ));
}

class _WrongFlavor extends StatelessWidget {
  const _WrongFlavor();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This is the connected app\'s entry point, built into the '
                'demo app.\n\nRun it with --flavor connected.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}
