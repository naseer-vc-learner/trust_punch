import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../demo/demo_data.dart' show isDemoId;
import '../models/attendance.dart';
import '../store/attendance_database.dart';
import '../store/attendance_store.dart';
import 'device_token.dart';
import 'server_api.dart';

/// Sends the phone's punches to the server, when it can.
///
/// Offline-first: punching never waits for this. Every saved punch is in
/// the outbox until the server has it; a resend after a lost answer is
/// harmless, because the server knows each punch by the id made here.
///
/// Demo data never leaves the phone.
class PunchSync extends ChangeNotifier {
  PunchSync({
    required this.store,
    required this.api,
    required this.tokens,
    this.every = const Duration(minutes: 1),
    this.batchSize = 200,
  });

  final AttendanceStore store;
  final ServerApi api;
  final TokenStore tokens;

  /// How often to try again while there is something to send.
  final Duration every;
  final int batchSize;

  String? _token;
  Timer? _timer;
  Timer? _soon;
  bool _disposed = false;

  /// The upload running now, if any, and whether another round was asked
  /// for while it ran.
  Future<void>? _running;
  bool _again = false;

  ServerHealth? health;

  /// Why the last attempt stopped, if it did.
  ServerException? problem;
  DateTime? lastSent;

  /// What the last attempt did, for the panel ("Send now" must answer).
  SyncOutcome? lastOutcome;
  int _sentInRun = 0;
  int _keptInRun = 0;

  /// The server's findings on punches sent this session: id → flags.
  final Map<String, List<String>> flags = {};

  bool get paired => _token != null;
  bool get busy => _running != null;
  int get waiting => store.punchesToSendCount;
  int get refused => store.punchesSentAs(AttendanceDatabase.refused);

  Future<void> start() async {
    _token = await tokens.read();
    store.addListener(_onStoreChanged);
    _timer = Timer.periodic(every, (_) => unawaited(syncNow()));
    unawaited(checkHealth());
    unawaited(syncNow());
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_onStoreChanged);
    _timer?.cancel();
    _soon?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    // Uploads finish in their own time; a closed screen no longer listens.
    if (!_disposed) super.notifyListeners();
  }

  /// A new punch: send it shortly (a gate queue punches in bursts).
  void _onStoreChanged() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
    notifyListeners();
  }

  Future<void> checkHealth() async {
    health = await api.health();
    notifyListeners();
  }

  /// Pairs this phone with a code from the server's operator.
  Future<void> pair(String code, String deviceName) async {
    final (_, token) = await api.pair(
      code: code.trim(),
      deviceName: deviceName.trim(),
      platform: Platform.isIOS
          ? 'ios'
          : Platform.isAndroid
              ? 'android'
              : 'other',
    );
    await tokens.write(token);
    _token = token;
    problem = null;
    notifyListeners();
    unawaited(syncNow());
  }

  /// Forgets the token. Punches stay in the outbox for the next pairing.
  Future<void> unpair() async {
    await tokens.delete();
    _token = null;
    notifyListeners();
  }

  /// Sends everything waiting, a batch at a time, until done or stopped.
  /// Called while an upload runs, it waits for that one and then runs once
  /// more, so a punch made meanwhile is not left behind.
  Future<void> syncNow() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _runUntilQuiet();
    _running = run;
    notifyListeners();
    return run;
  }

  Future<void> _runUntilQuiet() async {
    // A fresh attempt: an old "not reachable" must not outlive the outage.
    problem = null;
    _sentInRun = 0;
    _keptInRun = 0;
    try {
      do {
        _again = false;
        await _sendWaiting();
      } while (_again && !_disposed && problem == null);
    } finally {
      lastOutcome = SyncOutcome(
        at: DateTime.now(),
        paired: paired,
        sent: _sentInRun,
        keptOnPhone: _keptInRun,
        problem: problem,
        stillWaiting: waiting,
      );
      _running = null;
      notifyListeners();
    }
  }

  Future<void> _sendWaiting() async {
    final token = _token;
    if (token == null || _disposed) return;
    try {
      while (true) {
        final batch = store.punchesToSend(limit: batchSize);
        if (batch.isEmpty) break;

        final demo = [
          for (final p in batch)
            if (isDemoId(p.workerId)) p.id!,
        ];
        if (demo.isNotEmpty) {
          store.markSent(demo, AttendanceDatabase.keptOnPhone);
          _keptInRun += demo.length;
        }
        final real = [
          for (final p in batch)
            if (!isDemoId(p.workerId)) p,
        ];
        if (real.isEmpty) continue;

        final result =
            await api.uploadPunches(token, [for (final p in real) toServer(p)]);
        store.markSent(
            [...result.accepted, ...result.duplicates], AttendanceDatabase.uploaded);
        if (result.rejected.isNotEmpty) {
          store.markSent(result.rejected.keys, AttendanceDatabase.refused);
        }
        flags.addAll(result.flags);
        _sentInRun += result.accepted.length + result.duplicates.length;
        lastSent = DateTime.now();
        problem = null;
        notifyListeners();

        // Every punch sent must be answered for; otherwise stop rather than
        // send the same batch for ever.
        final answered = {
          ...result.accepted,
          ...result.duplicates,
          ...result.rejected.keys,
        };
        if (real.any((p) => !answered.contains(p.id))) {
          throw const ServerException(
              ServerProblem.other, 'Server did not answer for every punch');
        }
      }
    } on ServerException catch (e) {
      problem = e;
      if (e.problem == ServerProblem.notPaired) {
        // The server no longer knows this token (e.g. its data was reset).
        await tokens.delete();
        _token = null;
      }
    }
  }

  /// Whether [worker] is on the clock on another phone, as the server
  /// knows. Null when it cannot tell (not paired, offline, slow): the punch
  /// then goes ahead, and the server flags a clash when it arrives.
  Future<bool?> checkedInElsewhere(Worker worker) async {
    final token = _token;
    if (token == null || isDemoId(worker.id)) return null;
    try {
      final s = await api.openSession(token, worker.id, DateTime.now());
      return s.open && !s.onThisPhone;
    } on ServerException {
      return null;
    }
  }

  /// A punch as the server reads it. Times go as UTC plus the phone's time
  /// zone, so the server knows which local day it belongs to.
  Map<String, dynamic> toServer(Punch p) {
    final site = store.siteById(p.siteId);
    return {
      'id': p.id,
      'type': p.type.name,
      'at': p.at.toUtc().toIso8601String(),
      'offsetMinutes': p.at.timeZoneOffset.inMinutes,
      'workerId': p.workerId,
      'employeeId': p.employeeId,
      'workerName': p.workerName,
      'siteId': p.siteId,
      'siteName': p.siteName,
      if (site != null) 'siteLat': site.latitude,
      if (site != null) 'siteLng': site.longitude,
      'lat': p.latitude,
      'lng': p.longitude,
      'distance': p.distanceMeters,
      'auto': p.auto,
      'corrected': p.corrected,
      'clockSuspect': p.clockSuspect,
      if (p.replaces != null) 'replaces': p.replaces,
      if (p.via != null) 'via': p.via!.name,
    };
  }
}

/// One attempt to send, as the panel reports it.
class SyncOutcome {
  const SyncOutcome({
    required this.at,
    required this.paired,
    required this.sent,
    required this.keptOnPhone,
    required this.stillWaiting,
    this.problem,
  });

  final DateTime at;
  final bool paired;

  /// Now on the server (new, or already there from a lost answer).
  final int sent;

  /// Demo punches, which never leave the phone.
  final int keptOnPhone;
  final int stillWaiting;
  final ServerException? problem;

  String get summary {
    final p = problem;
    if (!paired) return 'Not paired: nothing sent';
    if (p != null) return 'Not sent: ${p.message} ($stillWaiting waiting)';
    final parts = [
      if (sent > 0) 'Sent $sent punch${sent == 1 ? '' : 'es'}',
      if (keptOnPhone > 0) '$keptOnPhone demo kept on phone',
    ];
    return parts.isEmpty
        ? 'Nothing waiting: everything is already on the server'
        : parts.join(' · ');
  }
}
