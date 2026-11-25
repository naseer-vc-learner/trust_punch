import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance.dart';

/// Standard day. Anything past this is overtime.
const standardDay = Duration(hours: 8);

/// Shift start, and how late counts as late.
const shiftStartHour = 9;
const lateGrace = Duration(minutes: 10);

/// Who this phone is for.
///
/// Individual: one person's own phone, so the app confirms that one face.
/// Team: a phone kept at the gate, so the app works out which of several
/// enrolled people has walked up.
enum AppMode { individual, team }

/// Everything the app knows, kept on the device only — no backend, no network.
class AttendanceStore extends ChangeNotifier {
  AttendanceStore._(
    this._prefs,
    this._punches,
    this._sites,
    this._workers,
    this._languageCode,
    this._mode,
    this._activeWorkerId,
  );

  static const _punchesKey = 'punches';
  static const _sitesKey = 'sites';
  static const _workersKey = 'workers';
  static const _languageKey = 'language';
  static const _modeKey = 'mode';
  static const _activeWorkerKey = 'activeWorker';

  final SharedPreferences _prefs;
  final List<Punch> _punches;
  final List<Site> _sites;
  final List<Worker> _workers;
  String _languageCode;
  AppMode _mode;
  String? _activeWorkerId;

  static Future<AttendanceStore> load() async {
    final prefs = await SharedPreferences.getInstance();

    final punches = (prefs.getStringList(_punchesKey) ?? const <String>[])
        .map((e) => Punch.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    final sites = (prefs.getStringList(_sitesKey) ?? const <String>[])
        .map((e) => Site.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    final workers = (prefs.getStringList(_workersKey) ?? const <String>[])
        .map((e) => Worker.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    return AttendanceStore._(
      prefs,
      punches,
      sites,
      workers,
      prefs.getString(_languageKey) ?? 'en',
      AppMode.values.byName(prefs.getString(_modeKey) ?? AppMode.team.name),
      prefs.getString(_activeWorkerKey),
    );
  }

  List<Site> get sites => List.unmodifiable(_sites);
  List<Worker> get workers => List.unmodifiable(_workers);
  String get languageCode => _languageCode;
  AppMode get mode => _mode;

  /// In individual mode, the one person this phone belongs to.
  Worker? get activeWorker {
    if (_workers.isEmpty) return null;
    for (final worker in _workers) {
      if (worker.id == _activeWorkerId) return worker;
    }
    return _workers.first;
  }

  Future<void> setMode(AppMode mode) async {
    _mode = mode;
    await _prefs.setString(_modeKey, mode.name);
    notifyListeners();
  }

  Future<void> setActiveWorker(String id) async {
    _activeWorkerId = id;
    await _prefs.setString(_activeWorkerKey, id);
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    _languageCode = code;
    await _prefs.setString(_languageKey, code);
    notifyListeners();
  }

  // ---------------------------------------------------------------- per worker

  List<Punch> punchesFor(String workerId, DateTime day) => _punches
      .where((p) => p.workerId == workerId && _isSameDay(p.at, day))
      .toList(growable: false);

  Punch? lastPunchFor(String workerId) {
    for (var i = _punches.length - 1; i >= 0; i--) {
      if (_punches[i].workerId == workerId) return _punches[i];
    }
    return null;
  }

  WorkerStatus statusOf(String workerId) => switch (lastPunchFor(workerId)?.type) {
        PunchType.checkIn || PunchType.breakEnd => WorkerStatus.working,
        PunchType.breakStart => WorkerStatus.onBreak,
        _ => WorkerStatus.off,
      };

  /// The punches that make sense next. This is the duplicate guard: anything
  /// not on this list would be a second check-in, a break inside a break, and
  /// so on.
  List<PunchType> allowedActions(String workerId) =>
      switch (statusOf(workerId)) {
        WorkerStatus.off => const [PunchType.checkIn],
        WorkerStatus.working => const [PunchType.checkOut, PunchType.breakStart],
        WorkerStatus.onBreak => const [PunchType.breakEnd],
      };

  /// The site of the session currently open, so a check-out closes where it
  /// opened even on a day spanning several sites.
  Site? openSiteFor(String workerId) {
    final last = lastPunchFor(workerId);
    if (last == null || last.type == PunchType.checkOut) return null;
    for (final site in _sites) {
      if (site.id == last.siteId) return site;
    }
    return null;
  }

  /// Time on the clock minus time on break.
  Duration workedOn(String workerId, DateTime day) =>
      _spanOn(workerId, day, counting: WorkerStatus.working);

  Duration breakOn(String workerId, DateTime day) =>
      _spanOn(workerId, day, counting: WorkerStatus.onBreak);

  Duration _spanOn(
    String workerId,
    DateTime day, {
    required WorkerStatus counting,
  }) {
    var total = Duration.zero;
    var state = WorkerStatus.off;
    DateTime? since;

    void close(DateTime at) {
      final from = since;
      if (from != null && state == counting) total += at.difference(from);
    }

    for (final punch in punchesFor(workerId, day)) {
      close(punch.at);
      state = switch (punch.type) {
        PunchType.checkIn || PunchType.breakEnd => WorkerStatus.working,
        PunchType.breakStart => WorkerStatus.onBreak,
        PunchType.checkOut => WorkerStatus.off,
      };
      since = punch.at;
    }
    // Only the current day keeps accruing; a session left open on a past day
    // simply never closed, and counting it to now would add whole days.
    if (_isSameDay(day, DateTime.now())) close(DateTime.now());
    return total;
  }

  Map<String, Duration> workedBySiteOn(String workerId, DateTime day) {
    final result = <String, Duration>{};
    var state = WorkerStatus.off;
    DateTime? since;
    String? siteName;

    for (final punch in punchesFor(workerId, day)) {
      if (since != null && state == WorkerStatus.working && siteName != null) {
        result[siteName] =
            (result[siteName] ?? Duration.zero) + punch.at.difference(since);
      }
      state = switch (punch.type) {
        PunchType.checkIn || PunchType.breakEnd => WorkerStatus.working,
        PunchType.breakStart => WorkerStatus.onBreak,
        PunchType.checkOut => WorkerStatus.off,
      };
      since = punch.at;
      siteName = punch.siteName;
    }
    if (since != null &&
        state == WorkerStatus.working &&
        siteName != null &&
        _isSameDay(day, DateTime.now())) {
      result[siteName] =
          (result[siteName] ?? Duration.zero) + DateTime.now().difference(since);
    }
    return result;
  }

  // ------------------------------------------------------------- shift rules

  /// Flags a supervisor cares about, derived rather than stored.
  ShiftFlags flagsFor(String workerId, DateTime day) {
    final punches = punchesFor(workerId, day);
    if (punches.isEmpty) return const ShiftFlags();

    final firstIn = punches.firstWhere(
      (p) => p.type == PunchType.checkIn,
      orElse: () => punches.first,
    );
    final shiftStart = DateTime(day.year, day.month, day.day, shiftStartHour);
    final worked = workedOn(workerId, day);

    // A day is judged short once it is over: either it ended in a check-out,
    // or it is a past day (an open session there stopped counting at the
    // day's last punch). Judging it by the worker's status right now would
    // hide every past short day while that worker is clocked in today.
    final dayOver = punches.last.type == PunchType.checkOut ||
        !_isSameDay(day, DateTime.now());

    return ShiftFlags(
      late: firstIn.at.isAfter(shiftStart.add(lateGrace)),
      overtime: worked > standardDay,
      short: dayOver && worked < standardDay,
    );
  }

  // ------------------------------------------------------------- whole day

  List<Punch> punchesOn(DateTime day) =>
      _punches.where((p) => _isSameDay(p.at, day)).toList(growable: false);

  /// Day-of-month to hours worked across everyone, for the calendar grid.
  Map<int, Duration> monthTotals(int year, int month) {
    final result = <int, Duration>{};
    for (final punch in _punches) {
      if (punch.at.year != year || punch.at.month != month) continue;
      result.putIfAbsent(punch.at.day, () {
        var total = Duration.zero;
        for (final worker in _workers) {
          total += workedOn(worker.id, punch.at);
        }
        return total;
      });
    }
    return result;
  }

  Duration monthTotal(int year, int month) =>
      monthTotals(year, month).values.fold(Duration.zero, (sum, d) => sum + d);

  // ------------------------------------------------------------------ writes

  Future<void> add(Punch punch) async {
    _punches.add(punch);
    await _prefs.setStringList(
      _punchesKey,
      _punches.map((p) => jsonEncode(p.toJson())).toList(),
    );
    notifyListeners();
  }

  Future<void> addWorker(Worker worker) async {
    _workers.add(worker);
    await _saveWorkers();
  }

  Future<void> removeWorker(String id) async {
    _workers.removeWhere((w) => w.id == id);
    await _saveWorkers();
  }

  Future<void> _saveWorkers() async {
    await _prefs.setStringList(
      _workersKey,
      _workers.map((w) => jsonEncode(w.toJson())).toList(),
    );
    notifyListeners();
  }

  Future<void> addSite(Site site) async {
    _sites.add(site);
    await _saveSites();
  }

  Future<void> removeSite(String id) async {
    _sites.removeWhere((s) => s.id == id);
    await _saveSites();
  }

  Future<void> _saveSites() async {
    await _prefs.setStringList(
      _sitesKey,
      _sites.map((s) => jsonEncode(s.toJson())).toList(),
    );
    notifyListeners();
  }

  Future<void> clearPunches() async {
    _punches.clear();
    await _prefs.remove(_punchesKey);
    notifyListeners();
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class ShiftFlags {
  const ShiftFlags({this.late = false, this.overtime = false, this.short = false});

  final bool late;
  final bool overtime;
  final bool short;

  bool get any => late || overtime || short;
}
