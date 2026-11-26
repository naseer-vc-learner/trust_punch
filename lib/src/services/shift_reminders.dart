import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/attendance.dart';

/// When to remind a worker who started (or resumed) work at [site] at
/// [now]: that location's shift end today, if it is still ahead. Null when
/// the shift has already ended (no reminder for overtime already running).
DateTime? reminderTimeFor(Site site, DateTime now) {
  final end = site.shiftEndOn(now);
  return end.isAfter(now) ? end : null;
}

/// A notification id that stays the same for a worker across app restarts,
/// so a check-out can cancel the reminder a check-in scheduled days ago.
/// (String.hashCode is not guaranteed stable between runs; FNV-1a is.)
int reminderIdFor(String workerId) {
  var hash = 0x811c9dc5;
  for (final unit in workerId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

/// Reminds a worker on their own phone that they are still checked in after
/// their shift. Gate phones never schedule these.
abstract interface class ShiftReminders {
  Future<void> remind({
    required String workerId,
    required DateTime at,
    required String title,
    required String body,
  });

  Future<void> cancel(String workerId);

  /// Replaced in tests.
  static ShiftReminders instance = LocalShiftReminders();
}

/// Phone notifications via flutter_local_notifications. Every failure is
/// swallowed: a reminder that cannot be set must never block a punch.
class LocalShiftReminders implements ShiftReminders {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  Future<void> _init() => _ready ??= _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Asked for when the first reminder is set, not at app start.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
        ),
      );

  Future<bool> _permitted() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, sound: true) ?? false;
    }
    return false;
  }

  @override
  Future<void> remind({
    required String workerId,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    try {
      await _init();
      if (!await _permitted()) return;
      await _plugin.zonedSchedule(
        id: reminderIdFor(workerId),
        // An absolute instant: UTC avoids needing the device's zone name.
        scheduledDate: tz.TZDateTime.from(at, tz.UTC),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'shift_reminders',
            'Shift reminders',
            channelDescription: 'Reminds you to finish work after your shift',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        // Inexact: needs no exact-alarm permission; a few minutes late is
        // fine for a reminder.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
      );
    } catch (e) {
      debugPrint('Shift reminder not set: $e');
    }
  }

  @override
  Future<void> cancel(String workerId) async {
    try {
      await _init();
      await _plugin.cancel(id: reminderIdFor(workerId));
    } catch (e) {
      debugPrint('Shift reminder not cancelled: $e');
    }
  }
}
