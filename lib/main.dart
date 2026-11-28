import 'package:flutter/material.dart';

import 'src/i18n/ui_text.dart';
import 'src/screens/role_root.dart';
import 'src/services/face_recognizer.dart';
import 'src/services/speech_service.dart';
import 'src/services/supervisor_lock.dart';
import 'src/store/attendance_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AttendanceStore.load();
  final lock = await SupervisorLock.load();
  runApp(TrustPunchApp(
    store: store,
    lock: lock,
    recognizer: FaceRecognizer(),
    speech: SpeechService(),
  ));
}

class TrustPunchApp extends StatelessWidget {
  const TrustPunchApp({
    super.key,
    required this.store,
    required this.lock,
    required this.recognizer,
    required this.speech,
    this.pickerFooter,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final FaceRecognizer recognizer;
  final SpeechService speech;

  /// Shown under the role picker. Nothing in this (demo) app; the connected
  /// app (lib/main_connected.dart) puts its server line here.
  final Widget? pickerFooter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'TrustPunch',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF00696D)),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF00696D),
          brightness: Brightness.dark,
        ),
        builder: (context, child) => Directionality(
          textDirection:
              isRtl(store.languageCode) ? TextDirection.rtl : TextDirection.ltr,
          child: child!,
        ),
        home: RoleRoot(
          store: store,
          lock: lock,
          recognizer: recognizer,
          speech: speech,
          pickerFooter: pickerFooter,
        ),
      ),
    );
  }
}
