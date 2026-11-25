import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/emulators.dart';
import '../core/providers.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/enrollment_screen.dart';
import '../features/ping/presence_ping_screen.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class TrustPunchApp extends ConsumerWidget {
  const TrustPunchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'TrustPunch',
      navigatorKey: navigatorKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const _Gate(),
    );
  }
}

/// Routes on auth + enrollment state, and drains the offline queue whenever the
/// app comes back to the foreground — that is the moment connectivity most
/// often returns.
class _Gate extends ConsumerStatefulWidget {
  const _Gate();

  @override
  ConsumerState<_Gate> createState() => _GateState();
}

class _GateState extends ConsumerState<_Gate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flush();
      _wireMessaging();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _flush();
  }

  Future<void> _flush() async {
    try {
      await ref.read(attendanceRepositoryProvider).flushQueue();
      if (!mounted) return;
      ref.invalidate(pendingSubmissionsProvider);
      ref.invalidate(myAttendanceProvider);
    } catch (_) {
      // Still offline. The queue keeps the capture; nothing is lost.
    }
  }

  Future<void> _wireMessaging() async {
    // FCM has no emulator, and a demo project has no sender to issue a token.
    // Skipping avoids a notification-permission prompt at launch that could
    // never lead to a delivered push anyway.
    if (useEmulator) {
      debugPrint('Emulator mode: FCM disabled. Presence pings will not arrive.');
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) {
        await ref.read(apiProvider).registerFcmToken(token);
      }
      FirebaseMessaging.onMessage.listen(_handlePing);
      FirebaseMessaging.onMessageOpenedApp.listen(_handlePing);
      final initial = await messaging.getInitialMessage();
      if (initial != null) _handlePing(initial);
    } catch (_) {
      // Push is a convenience for presence checks; its absence must not stop
      // the employee from checking in normally.
    }
  }

  void _handlePing(RemoteMessage message) {
    if (message.data['kind'] != 'presence_ping') return;
    final pingId = message.data['pingId'] as String?;
    final expiresAtMs = int.tryParse('${message.data['expiresAtMs']}');
    if (pingId == null || expiresAtMs == null) return;

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => PresencePingScreen(
          pingId: pingId,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);

    return auth.when(
      loading: () => const _Splash(),
      error: (e, _) => _Splash(message: 'Sign-in failed: $e'),
      data: (user) {
        if (user == null) return const _SignInScreen();
        final employee = ref.watch(currentEmployeeProvider);
        return employee.when(
          loading: () => const _Splash(),
          error: (e, _) => _Splash(message: '$e'),
          data: (emp) {
            if (emp == null) {
              return const _Splash(
                message: 'No employee record exists for this account. '
                    'Ask your administrator to create one.',
              );
            }
            return emp.isEnrolled ? const HomeScreen() : const EnrollmentScreen();
          },
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({this.message});
  final String? message;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.verified_user_outlined, size: 56),
                const SizedBox(height: 16),
                if (message == null)
                  const CircularProgressIndicator()
                else
                  Text(message!, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
}

class _SignInScreen extends ConsumerStatefulWidget {
  const _SignInScreen();

  @override
  ConsumerState<_SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<_SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(firebaseAuthProvider).signInWithEmailAndPassword(
            email: _email.text.trim(),
            password: _password.text,
          );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_user_outlined, size: 56),
              const SizedBox(height: 12),
              Text('TrustPunch', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                key: const Key('signin-email'),
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Work email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                key: const Key('signin-password'),
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('signin-submit'),
                onPressed: _busy ? null : _signIn,
                child: Text(_busy ? 'Signing in…' : 'Sign in'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
