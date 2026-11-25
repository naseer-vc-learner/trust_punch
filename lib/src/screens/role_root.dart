import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../services/face_recognizer.dart';
import '../services/speech_service.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'kiosk_home.dart';
import 'shared_widgets.dart';
import 'supervisor_home.dart';
import 'supervisor_pin.dart';
import 'worker_home.dart';

/// Decides which home screen the phone shows: the role picker, or the home
/// of the worker, gate kiosk or supervisor role.
///
/// Worker and kiosk are remembered across restarts; supervisor never is, and
/// its session ends on "Change user", on restart, or when the app has been
/// in the background longer than [_supervisorIdleLimit].
class RoleRoot extends StatefulWidget {
  const RoleRoot({
    super.key,
    required this.store,
    required this.lock,
    required this.recognizer,
    required this.speech,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final FaceRecognizer recognizer;
  final SpeechService speech;

  @override
  State<RoleRoot> createState() => _RoleRootState();
}

/// Long enough for a permission dialog or a quick look at another app, short
/// enough that a phone left behind does not stay in the supervisor screens.
const _supervisorIdleLimit = Duration(minutes: 2);

class _RoleRootState extends State<RoleRoot> {
  late AppRole? _role = widget.store.lastRole;
  late final AppLifecycleListener _lifecycle;
  DateTime? _hiddenAt;

  String get _lang => widget.store.languageCode;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final hiddenAt = _hiddenAt;
        _hiddenAt = null;
        if (_role == AppRole.supervisor &&
            hiddenAt != null &&
            DateTime.now().difference(hiddenAt) > _supervisorIdleLimit) {
          _exit();
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.speech.setLanguage(_lang);
      await widget.speech.refreshAvailable();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.speech.stop();
    super.dispose();
  }

  Future<void> _enter(AppRole role) async {
    if (role == AppRole.supervisor) {
      if (!await requireSupervisor(context, widget.lock, _lang)) return;
      widget.lock.beginSession();
    }
    await widget.store.setLastRole(role);
    if (mounted) setState(() => _role = role);
  }

  Future<void> _exit() async {
    widget.lock.endSession();
    // Close anything opened from the home screen, so nothing from the last
    // role stays on the stack behind the picker.
    Navigator.of(context).popUntil((route) => route.isFirst);
    await widget.store.setLastRole(null);
    if (mounted) setState(() => _role = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => switch (_role) {
        null => _RolePicker(
            store: widget.store,
            speech: widget.speech,
            onPick: _enter,
          ),
        AppRole.worker => WorkerHome(
            store: widget.store,
            lock: widget.lock,
            recognizer: widget.recognizer,
            speech: widget.speech,
            onSwitchRole: _exit,
          ),
        AppRole.kiosk => KioskHome(
            store: widget.store,
            recognizer: widget.recognizer,
            speech: widget.speech,
            onSwitchRole: _exit,
          ),
        AppRole.supervisor => SupervisorHome(
            store: widget.store,
            lock: widget.lock,
            recognizer: widget.recognizer,
            speech: widget.speech,
            onSwitchRole: _exit,
          ),
      },
    );
  }
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({
    required this.store,
    required this.speech,
    required this.onPick,
  });

  final AttendanceStore store;
  final SpeechService speech;
  final ValueChanged<AppRole> onPick;

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 12),
            Text('TrustPunch',
                style: text.headlineLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(t(lang, T.chooseRole),
                style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            LanguageChips(store: store, speech: speech),
            const SizedBox(height: 24),
            _RoleCard(
              color: const Color(0xFF2E7D32),
              icon: Icons.person,
              title: t(lang, T.roleWorker),
              subtitle: t(lang, T.individualMode),
              onTap: () => onPick(AppRole.worker),
            ),
            const SizedBox(height: 16),
            _RoleCard(
              color: const Color(0xFF00696D),
              icon: Icons.groups,
              title: t(lang, T.roleKiosk),
              subtitle: t(lang, T.teamMode),
              onTap: () => onPick(AppRole.kiosk),
            ),
            const SizedBox(height: 16),
            _RoleCard(
              color: const Color(0xFF37474F),
              icon: Icons.admin_panel_settings,
              title: t(lang, T.roleSupervisor),
              subtitle: t(lang, T.enterSupervisorPin),
              trailing: Icons.lock_outline,
              onTap: () => onPick(AppRole.supervisor),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          child: Row(
            children: [
              Icon(icon, size: 48, color: Colors.white),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
              if (trailing != null) Icon(trailing, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
