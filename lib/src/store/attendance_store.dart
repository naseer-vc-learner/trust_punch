import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance.dart';
import '../models/leave.dart';
import '../models/project.dart';
import '../models/requests.dart';
import '../services/location_service.dart' show haversineMeters;

/// Standard day, whatever the locations' shifts: anything past this is
/// overtime (the UAE limit is 8 hours a day).
const standardDay = Duration(hours: 8);

/// How late after a location's shift start still counts as on time.
const lateGrace = Duration(minutes: 10);

/// How far the phone's clock may sit behind the newest punch before a new
/// punch is refused as a clock set back.
const clockTolerance = Duration(minutes: 2);

/// How far the phone's clock may differ from the GPS time before a punch is
/// flagged for the supervisor.
const gpsClockTolerance = Duration(minutes: 5);

/// Assumed speed between two locations of a project, for estimating travel
/// when a worker moves without checking out: 30 km/h, city traffic.
const travelSpeedMetersPerSecond = 30000 / 3600;

/// What a worker may do next at one location, and anything the app has to
/// record first to make it legal.
class PunchPlan {
  const PunchPlan({required this.actions, this.autoClose});

  final List<PunchType> actions;

  /// A check-out the app adds before the worker's own punch: it closes a
  /// session left open at another location, or on an earlier day.
  final Punch? autoClose;
}

/// Who is using the phone, and so which home screen they get.
///
/// Worker: one person's own phone; the app confirms that one face (1:1).
/// Kiosk: a phone kept at the gate for a team; the app works out which of
/// several enrolled people has walked up (1:N).
/// Supervisor: manages workers, sites, leave and attendance, behind the PIN.
enum AppRole { worker, kiosk, supervisor }

/// Everything the app knows, kept on the device only — no backend, no network.
class AttendanceStore extends ChangeNotifier {
  AttendanceStore._(
    this._prefs,
    this._punches,
    this._sites,
    this._workers,
    this._leaves,
    this._projects,
    this._overtime,
    this._corrections,
    this._languageCode,
    this._lastRole,
    this._activeWorkerId,
  );

  static const _overtimeKey = 'overtime';
  static const _correctionsKey = 'corrections';

  final List<OvertimeDecision> _overtime;
  final List<CorrectionRequest> _corrections;

  static const _punchesKey = 'punches';
  static const _sitesKey = 'sites';
  static const _workersKey = 'workers';
  static const _leavesKey = 'leaves';
  static const _projectsKey = 'projects';
  static const _languageKey = 'language';
  static const _roleKey = 'role';
  static const _activeWorkerKey = 'activeWorker';

  final SharedPreferences _prefs;
  final List<Punch> _punches;
  final List<Site> _sites;
  final List<Worker> _workers;
  final List<LeaveRequest> _leaves;
  final List<Project> _projects;
  String _languageCode;
  AppRole? _lastRole;
  String? _activeWorkerId;

  static Future<AttendanceStore> load() async {
    final prefs = await SharedPreferences.getInstance();

    final punches = (prefs.getStringList(_punchesKey) ?? const <String>[])
        .map((e) => Punch.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    var sites = (prefs.getStringList(_sitesKey) ?? const <String>[])
        .map((e) => Site.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    var workers = (prefs.getStringList(_workersKey) ?? const <String>[])
        .map((e) => Worker.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    final leaves = (prefs.getStringList(_leavesKey) ?? const <String>[])
        .map((e) =>
            LeaveRequest.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    final projects = (prefs.getStringList(_projectsKey) ?? const <String>[])
        .map((e) => Project.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    // Sites and workers saved before projects existed belong to no project,
    // and so could never punch. They move into "General" once, and are saved
    // back, so nothing recorded before is lost.
    if (sites.any((s) => s.projectId.isEmpty) ||
        workers.any((w) => w.projectId.isEmpty)) {
      if (!projects.any((p) => p.id == generalProjectId)) {
        projects.add(const Project(id: generalProjectId, name: 'General'));
      }
      sites = [
        for (final s in sites)
          s.projectId.isEmpty ? s.copyWith(projectId: generalProjectId) : s,
      ];
      workers = [
        for (final w in workers)
          w.projectId.isEmpty ? w.copyWith(projectId: generalProjectId) : w,
      ];
      await prefs.setStringList(
          _projectsKey, [for (final p in projects) jsonEncode(p.toJson())]);
      await prefs.setStringList(
          _sitesKey, [for (final s in sites) jsonEncode(s.toJson())]);
      await prefs.setStringList(
          _workersKey, [for (final w in workers) jsonEncode(w.toJson())]);
    }

    final overtime = (prefs.getStringList(_overtimeKey) ?? const <String>[])
        .map((e) =>
            OvertimeDecision.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    final corrections =
        (prefs.getStringList(_correctionsKey) ?? const <String>[])
            .map((e) => CorrectionRequest.fromJson(
                jsonDecode(e) as Map<String, dynamic>))
            .toList();

    // Corrections insert punches at their real time, so the list is kept in
    // time order; older saves made in arrival order are sorted once here.
    punches.sort((a, b) => a.at.compareTo(b.at));

    return AttendanceStore._(
      prefs,
      punches,
      sites,
      workers,
      leaves,
      projects,
      overtime,
      corrections,
      prefs.getString(_languageKey) ?? 'en',
      _parseRole(prefs.getString(_roleKey)),
      prefs.getString(_activeWorkerKey),
    );
  }

  /// Only worker and kiosk are ever restored, so reopening the app can never
  /// land in the supervisor screens without the PIN.
  static AppRole? _parseRole(String? name) => switch (name) {
        'worker' => AppRole.worker,
        'kiosk' => AppRole.kiosk,
        _ => null,
      };

  List<Site> get sites => List.unmodifiable(_sites);
  List<Worker> get workers => List.unmodifiable(_workers);
  List<Project> get projects => List.unmodifiable(_projects);
  String get languageCode => _languageCode;

  Site? siteById(String id) {
    for (final site in _sites) {
      if (site.id == id) return site;
    }
    return null;
  }

  Project? projectById(String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  List<Site> sitesOf(String projectId) =>
      _sites.where((s) => s.projectId == projectId).toList(growable: false);

  List<Worker> workersOf(String projectId) =>
      _workers.where((w) => w.projectId == projectId).toList(growable: false);

  /// The role the phone reopens in; null means show the role picker.
  AppRole? get lastRole => _lastRole;

  Future<void> setLastRole(AppRole? role) async {
    _lastRole = role == AppRole.supervisor ? null : role;
    final saved = _lastRole;
    if (saved == null) {
      await _prefs.remove(_roleKey);
    } else {
      await _prefs.setString(_roleKey, saved.name);
    }
    notifyListeners();
  }

  /// The one person a personal (worker-role) phone belongs to.
  Worker? get activeWorker {
    if (_workers.isEmpty) return null;
    for (final worker in _workers) {
      if (worker.id == _activeWorkerId) return worker;
    }
    return _workers.first;
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

  /// Whether [worker] may punch at [site]: only at their own project's
  /// locations, so hours can never land on a project they are not on.
  bool canPunchAt(Worker worker, Site site) =>
      worker.projectId.isNotEmpty && worker.projectId == site.projectId;

  /// What [workerId] may do next at [site], at time [now].
  ///
  /// This is the duplicate guard (no second check-in, no break inside a
  /// break) and the multi-location rule:
  /// - nothing open: check in;
  /// - open here, today: check out or break (or end the break);
  /// - open at another location: check in here, and the other location is
  ///   closed first by [PunchPlan.autoClose], at this check-in minus the
  ///   estimated travel time, never before the worker's last punch there;
  /// - left open on an earlier day: closed at that location's shift end that
  ///   day, then check in, so a forgotten check-out never adds whole nights.
  PunchPlan planAt(String workerId, Site site, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final last = lastPunchFor(workerId);
    if (last == null || last.type == PunchType.checkOut) {
      return const PunchPlan(actions: [PunchType.checkIn]);
    }

    final openSite = siteById(last.siteId);
    final earlierDay = !_isSameDay(last.at, at);
    if (!earlierDay && last.siteId == site.id) {
      return PunchPlan(
        actions: statusOf(workerId) == WorkerStatus.onBreak
            ? const [PunchType.breakEnd]
            : const [PunchType.checkOut, PunchType.breakStart],
      );
    }

    final DateTime closeAt;
    if (earlierDay) {
      final shiftEnd = openSite?.shiftEndOn(last.at);
      closeAt = shiftEnd == null || shiftEnd.isBefore(last.at)
          ? last.at
          : shiftEnd;
    } else {
      final travel = openSite == null ? Duration.zero : travelBetween(openSite, site);
      final estimate = at.subtract(travel);
      closeAt = estimate.isBefore(last.at) ? last.at : estimate;
    }

    return PunchPlan(
      actions: const [PunchType.checkIn],
      autoClose: Punch(
        type: PunchType.checkOut,
        at: closeAt,
        workerId: last.workerId,
        employeeId: last.employeeId,
        workerName: last.workerName,
        siteId: last.siteId,
        siteName: last.siteName,
        latitude: openSite?.latitude ?? last.latitude,
        longitude: openSite?.longitude ?? last.longitude,
        distanceMeters: 0,
        auto: true,
      ),
    );
  }

  /// Estimated travel time between two locations: straight-line distance at
  /// [travelSpeedMetersPerSecond]. An estimate, shown as such.
  static Duration travelBetween(Site from, Site to) {
    final meters = haversineMeters(
        from.latitude, from.longitude, to.latitude, to.longitude);
    return Duration(seconds: (meters / travelSpeedMetersPerSecond).round());
  }

  /// Saves the worker's own [punch], after any check-out [plan] needs first,
  /// as one write.
  Future<void> recordPunch(PunchPlan plan, Punch punch) async {
    final auto = plan.autoClose;
    if (auto != null) _insertSorted(auto);
    _insertSorted(punch);
    await _savePunches();
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

  /// Hours worked at each location on [day], keyed by location name for
  /// display. Two locations with the same name are added together; use
  /// [workedBySiteIdOn] when they must stay apart.
  Map<String, Duration> workedBySiteOn(String workerId, DateTime day) {
    final names = <String, String>{
      for (final p in punchesFor(workerId, day)) p.siteId: p.siteName,
    };
    final result = <String, Duration>{};
    workedBySiteIdOn(workerId, day).forEach((id, hours) {
      final name = names[id] ?? id;
      result[name] = (result[name] ?? Duration.zero) + hours;
    });
    return result;
  }

  /// Hours worked at each location on [day], keyed by location id.
  Map<String, Duration> workedBySiteIdOn(String workerId, DateTime day) {
    final result = <String, Duration>{};
    var state = WorkerStatus.off;
    DateTime? since;
    String? siteId;

    for (final punch in punchesFor(workerId, day)) {
      if (since != null && state == WorkerStatus.working && siteId != null) {
        result[siteId] =
            (result[siteId] ?? Duration.zero) + punch.at.difference(since);
      }
      state = switch (punch.type) {
        PunchType.checkIn || PunchType.breakEnd => WorkerStatus.working,
        PunchType.breakStart => WorkerStatus.onBreak,
        PunchType.checkOut => WorkerStatus.off,
      };
      since = punch.at;
      siteId = punch.siteId;
    }
    if (since != null &&
        state == WorkerStatus.working &&
        siteId != null &&
        _isSameDay(day, DateTime.now())) {
      result[siteId] =
          (result[siteId] ?? Duration.zero) + DateTime.now().difference(since);
    }
    return result;
  }

  /// One project's day at a glance: who is at each location right now, the
  /// hours each location has had today, and what a supervisor should check.
  ProjectToday projectToday(String projectId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final workers = workersOf(projectId);
    final working = <String, List<Worker>>{};
    final onBreak = <String, List<Worker>>{};
    final hours = <String, Duration>{};
    final notIn = <Worker>[];
    final onLeave = <Worker>[];
    final afterShift = <(Worker, Site)>[];
    var total = Duration.zero;
    var travel = Duration.zero;
    var late = 0;
    var auto = 0;

    for (final w in workers) {
      final last = lastPunchFor(w.id);
      // "Here now" means a session opened today and not closed. One left
      // open on an earlier day is not someone on site.
      final openToday = last != null &&
          last.type != PunchType.checkOut &&
          _isSameDay(last.at, at);
      if (openToday) {
        (last.type == PunchType.breakStart ? onBreak : working)
            .putIfAbsent(last.siteId, () => [])
            .add(w);
        final site = siteById(last.siteId);
        if (site != null && at.isAfter(site.shiftEndOn(at))) {
          afterShift.add((w, site));
        }
      } else if (leaveOn(w.id, at) != null) {
        onLeave.add(w);
      } else if (punchesFor(w.id, at).isEmpty) {
        notIn.add(w);
      }

      workedBySiteIdOn(w.id, at).forEach((siteId, d) {
        hours[siteId] = (hours[siteId] ?? Duration.zero) + d;
        total += d;
      });
      travel += travelOn(w.id, at);
      final flags = flagsFor(w.id, at);
      if (flags.late) late++;
      if (flags.autoCheckout) auto++;
    }

    return ProjectToday(
      locations: [
        for (final site in sitesOf(projectId))
          LocationNow(
            site: site,
            working: working[site.id] ?? const [],
            onBreak: onBreak[site.id] ?? const [],
            hoursToday: hours[site.id] ?? Duration.zero,
          ),
      ],
      notIn: notIn,
      onLeave: onLeave,
      afterShift: afterShift,
      totalHours: total,
      travel: travel,
      late: late,
      autoCheckouts: auto,
    );
  }

  /// Time between leaving one location and checking in at another on [day]:
  /// travel, not work, and not paid as hours at either location.
  Duration travelOn(String workerId, DateTime day) {
    var total = Duration.zero;
    Punch? lastOut;
    for (final punch in punchesFor(workerId, day)) {
      if (punch.type == PunchType.checkOut) {
        lastOut = punch;
      } else if (punch.type == PunchType.checkIn) {
        final out = lastOut;
        if (out != null && out.siteId != punch.siteId) {
          total += punch.at.difference(out.at);
        }
        lastOut = null;
      }
    }
    return total;
  }

  // ------------------------------------------------------------- shift rules

  /// Flags a supervisor cares about, derived rather than stored.
  ShiftFlags flagsFor(String workerId, DateTime day) {
    final punches = punchesFor(workerId, day);
    if (punches.isEmpty) return const ShiftFlags();

    final firstIn = _firstIn(punches);
    final worked = workedOn(workerId, day);

    return ShiftFlags(
      late: firstIn.at.isAfter(_shiftStartFor(firstIn, day).add(lateGrace)),
      overtime: worked > standardDay,
      short: _dayOver(punches, day) && worked < standardDay,
      autoCheckout: punches.any((p) => p.auto),
      corrected: punches.any((p) => p.corrected),
      clockSuspect: punches.any((p) => p.clockSuspect),
    );
  }

  static Punch _firstIn(List<Punch> punches) => punches.firstWhere(
        (p) => p.type == PunchType.checkIn,
        orElse: () => punches.first,
      );

  /// Late is judged against the shift of the location the day started at.
  DateTime _shiftStartFor(Punch firstIn, DateTime day) =>
      siteById(firstIn.siteId)?.shiftStartOn(day) ??
      DateTime(day.year, day.month, day.day)
          .add(const Duration(minutes: Site.defaultShiftStart));

  /// A day is judged once it is over: it ended in a check-out, or it is a
  /// past day (an open session there stopped counting at its last punch).
  /// Judging by the worker's status right now would hide every past day
  /// while that worker is clocked in today.
  static bool _dayOver(List<Punch> punches, DateTime day) =>
      punches.isNotEmpty &&
      (punches.last.type == PunchType.checkOut ||
          !_isSameDay(day, DateTime.now()));

  /// One worker's day for the supervisor: times, lateness, break, hours.
  WorkerDay workerDay(String workerId, DateTime day) {
    final punches = punchesFor(workerId, day);
    if (punches.isEmpty) return const WorkerDay();
    final firstIn = _firstIn(punches);
    final shiftStart = _shiftStartFor(firstIn, day);
    final late = firstIn.at.isAfter(shiftStart.add(lateGrace));
    final last = punches.last;
    return WorkerDay(
      firstIn: firstIn.at,
      lastOut: last.type == PunchType.checkOut ? last.at : null,
      lateBy: late ? firstIn.at.difference(shiftStart) : Duration.zero,
      worked: workedOn(workerId, day),
      breaks: breakOn(workerId, day),
      travel: travelOn(workerId, day),
      overtime: overtimeOn(workerId, day),
      overtimeStatus: overtimeStatus(workerId, day),
    );
  }

  // ---------------------------------------------------------------- overtime

  /// Worked time beyond the 8-hour day, before any approval.
  Duration overtimeOn(String workerId, DateTime day) {
    final worked = workedOn(workerId, day);
    return worked > standardDay ? worked - standardDay : Duration.zero;
  }

  OvertimeDecision? overtimeDecision(String workerId, DateTime day) {
    for (final d in _overtime) {
      if (d.workerId == workerId && _isSameDay(d.date, day)) return d;
    }
    return null;
  }

  /// Null when there is no overtime that day.
  RequestStatus? overtimeStatus(String workerId, DateTime day) {
    if (overtimeOn(workerId, day) == Duration.zero) return null;
    final decision = overtimeDecision(workerId, day);
    if (decision == null) return RequestStatus.pending;
    return decision.approved ? RequestStatus.approved : RequestStatus.rejected;
  }

  /// Days with overtime still to decide, newest first. Only finished days:
  /// overtime still growing today is decided once the worker checks out.
  List<(Worker, DateTime)> get pendingOvertime {
    final result = <(Worker, DateTime)>[];
    for (final worker in _workers) {
      final days = {
        for (final p in _punches)
          if (p.workerId == worker.id) DateTime(p.at.year, p.at.month, p.at.day),
      };
      for (final day in days) {
        if (overtimeStatus(worker.id, day) == RequestStatus.pending &&
            _dayOver(punchesFor(worker.id, day), day)) {
          result.add((worker, day));
        }
      }
    }
    result.sort((a, b) => b.$2.compareTo(a.$2));
    return result;
  }

  int get pendingOvertimeCount => pendingOvertime.length;

  /// Every overtime decision, newest day first.
  List<OvertimeDecision> get overtimeDecisions => List.unmodifiable(
        [..._overtime]..sort((a, b) => b.date.compareTo(a.date)),
      );

  /// Approves or rejects one day's overtime. A decided day is left alone.
  Future<void> decideOvertime(
    String workerId,
    DateTime day, {
    required bool approve,
  }) async {
    if (overtimeDecision(workerId, day) != null) return;
    _overtime.add(OvertimeDecision(
      workerId: workerId,
      date: DateTime(day.year, day.month, day.day),
      approved: approve,
      minutes: approve ? overtimeOn(workerId, day).inMinutes : 0,
      decidedAt: DateTime.now(),
    ));
    await _prefs.setStringList(
      _overtimeKey,
      _overtime.map((d) => jsonEncode(d.toJson())).toList(),
    );
    notifyListeners();
  }

  /// Hours to pay for a day: up to 8 hours, plus overtime only as approved.
  Duration payableOn(String workerId, DateTime day) {
    final worked = workedOn(workerId, day);
    final base = worked > standardDay ? standardDay : worked;
    final decision = overtimeDecision(workerId, day);
    if (decision == null || !decision.approved) return base;
    final extra = overtimeOn(workerId, day);
    final approved = Duration(minutes: decision.minutes);
    return base + (extra < approved ? extra : approved);
  }

  // -------------------------------------------------------------- clock check

  /// True when the phone's clock is earlier than the newest punch already
  /// recorded, beyond a small tolerance: the clock was set back, which would
  /// let someone record a punch at a time they were not there.
  bool clockLooksWrong(DateTime now) {
    if (_punches.isEmpty) return false;
    var newest = _punches.first.at;
    for (final p in _punches) {
      if (p.at.isAfter(newest)) newest = p.at;
    }
    return now.isBefore(newest.subtract(clockTolerance));
  }

  // ------------------------------------------------------------- corrections

  /// Every correction request, newest first.
  List<CorrectionRequest> get corrections => List.unmodifiable(
        [..._corrections]..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)),
      );

  int get pendingCorrectionCount =>
      _corrections.where((c) => c.status == RequestStatus.pending).length;

  /// Files a request to fix a missed check-in or check-out. Throws
  /// [ArgumentError] for anything else, a time in the future, a missing
  /// reason, or a location outside the worker's project.
  Future<CorrectionRequest> requestCorrection({
    required Worker worker,
    required Site site,
    required PunchType type,
    required DateTime at,
    required String reason,
    DateTime? now,
  }) async {
    if (type != PunchType.checkIn && type != PunchType.checkOut) {
      throw ArgumentError('Only check-in and check-out can be corrected');
    }
    if (at.isAfter(now ?? DateTime.now())) {
      throw ArgumentError('A correction cannot be in the future');
    }
    if (reason.trim().isEmpty) throw ArgumentError('A reason is required');
    if (!canPunchAt(worker, site)) {
      throw ArgumentError('Not a location of this worker\'s project');
    }
    final request = CorrectionRequest(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      workerId: worker.id,
      workerName: worker.name,
      siteId: site.id,
      siteName: site.name,
      type: type,
      at: at,
      reason: reason.trim(),
      status: RequestStatus.pending,
      requestedAt: now ?? DateTime.now(),
    );
    _corrections.add(request);
    await _saveCorrections();
    return request;
  }

  /// Approves or rejects a pending request. Throws [StateError] when an
  /// approval would leave the day's punches out of order (e.g. a check-out
  /// before its own check-in); the request then stays pending.
  ///
  /// An approved check-out replaces the closing punch of the session it
  /// falls in (typically an automatic one); an approved check-in replaces a
  /// later check-in that started the same session. Otherwise the punch is
  /// added. Either way it is marked corrected.
  Future<void> decideCorrection(String id, {required bool approve}) async {
    final i = _corrections.indexWhere((c) => c.id == id);
    if (i < 0 || _corrections[i].status != RequestStatus.pending) return;
    final request = _corrections[i];

    if (!approve) {
      _corrections[i] = request.decided(RequestStatus.rejected, DateTime.now());
      await _saveCorrections();
      return;
    }

    final day = punchesFor(request.workerId, request.at);
    final replaced = _punchReplacedBy(request, day);
    final site = siteById(request.siteId);
    final worker = _workers.where((w) => w.id == request.workerId).firstOrNull;
    final corrected = Punch(
      type: request.type,
      at: request.at,
      workerId: request.workerId,
      employeeId: worker?.employeeId ?? '',
      workerName: request.workerName,
      siteId: request.siteId,
      siteName: request.siteName,
      latitude: site?.latitude ?? 0,
      longitude: site?.longitude ?? 0,
      distanceMeters: 0,
      corrected: true,
    );

    final after = [
      for (final p in day)
        if (!identical(p, replaced)) p,
      corrected,
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (!validDay(after)) {
      throw StateError('This correction does not fit the punches of that day');
    }

    if (replaced != null) _punches.remove(replaced);
    _insertSorted(corrected);
    _corrections[i] = request.decided(
      RequestStatus.approved,
      DateTime.now(),
      replacedAt: replaced?.at,
      replacedAuto: replaced?.auto ?? false,
    );
    await _savePunches();
    await _saveCorrections();
  }

  Punch? _punchReplacedBy(CorrectionRequest request, List<Punch> day) {
    if (request.type == PunchType.checkOut) {
      // The session the time falls in starts at the last check-in before it;
      // its closing punch is the first check-out after that check-in.
      Punch? sessionStart;
      for (final p in day) {
        if (p.type == PunchType.checkIn && !p.at.isAfter(request.at)) {
          sessionStart = p;
        }
      }
      if (sessionStart == null) return null;
      for (final p in day) {
        if (p.type == PunchType.checkOut && p.at.isAfter(sessionStart.at)) {
          return p;
        }
      }
      return null;
    }
    // A check-in replaces the next punch only if that is itself a check-in:
    // the worker checked in late and is moving the start earlier.
    for (final p in day) {
      if (p.at.isAfter(request.at)) {
        return p.type == PunchType.checkIn ? p : null;
      }
    }
    return null;
  }

  /// Whether a day's punches, in time order, follow the allowed sequence:
  /// in → (break start → break end)* → out, any number of times.
  static bool validDay(List<Punch> punches) {
    var state = WorkerStatus.off;
    for (final p in punches) {
      switch (p.type) {
        case PunchType.checkIn:
          if (state != WorkerStatus.off) return false;
          state = WorkerStatus.working;
        case PunchType.breakStart:
          if (state != WorkerStatus.working) return false;
          state = WorkerStatus.onBreak;
        case PunchType.breakEnd:
          if (state != WorkerStatus.onBreak) return false;
          state = WorkerStatus.working;
        case PunchType.checkOut:
          // A session may be closed from a break (automatic check-out).
          if (state == WorkerStatus.off) return false;
          state = WorkerStatus.off;
      }
    }
    return true;
  }

  void _insertSorted(Punch punch) {
    final at = _punches.indexWhere((p) => p.at.isAfter(punch.at));
    if (at < 0) {
      _punches.add(punch);
    } else {
      _punches.insert(at, punch);
    }
  }

  Future<void> _saveCorrections() async {
    await _prefs.setStringList(
      _correctionsKey,
      _corrections.map((c) => jsonEncode(c.toJson())).toList(),
    );
    notifyListeners();
  }

  // ------------------------------------------------------------- whole day

  // Passing [workerId] narrows any of these to that one person, which is how
  // a worker's own calendar shows only their own days.

  List<Punch> punchesOn(DateTime day, {String? workerId}) => _punches
      .where((p) =>
          _isSameDay(p.at, day) && (workerId == null || p.workerId == workerId))
      .toList(growable: false);

  /// Day-of-month to hours worked, for the calendar grid.
  Map<int, Duration> monthTotals(int year, int month, {String? workerId}) {
    final people = workerId == null
        ? _workers
        : _workers.where((w) => w.id == workerId);
    final result = <int, Duration>{};
    for (final punch in _punches) {
      if (punch.at.year != year || punch.at.month != month) continue;
      if (workerId != null && punch.workerId != workerId) continue;
      result.putIfAbsent(punch.at.day, () {
        var total = Duration.zero;
        for (final worker in people) {
          total += workedOn(worker.id, punch.at);
        }
        return total;
      });
    }
    return result;
  }

  Duration monthTotal(int year, int month, {String? workerId}) =>
      monthTotals(year, month, workerId: workerId)
          .values
          .fold(Duration.zero, (sum, d) => sum + d);

  // ------------------------------------------------------------------ writes

  Future<void> add(Punch punch) async {
    _insertSorted(punch);
    await _savePunches();
  }

  Future<void> _savePunches() async {
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

  /// Puts [workerId] on [projectId] with a role and job. Moving to another
  /// project is allowed; hours already recorded stay where they were worked.
  Future<void> assignWorker(
    String workerId, {
    required String projectId,
    required String role,
    required String job,
  }) async {
    final i = _workers.indexWhere((w) => w.id == workerId);
    if (i < 0) return;
    _workers[i] =
        _workers[i].copyWith(projectId: projectId, role: role, job: job);
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

  /// Changes a location's shift. Throws [ArgumentError] when it would end
  /// before it starts (overnight shifts are not supported yet).
  Future<void> setShift(String siteId, int startMinutes, int endMinutes) async {
    if (endMinutes <= startMinutes) {
      throw ArgumentError('Shift must end after it starts');
    }
    final i = _sites.indexWhere((s) => s.id == siteId);
    if (i < 0) return;
    _sites[i] = _sites[i]
        .copyWith(shiftStartMinutes: startMinutes, shiftEndMinutes: endMinutes);
    await _saveSites();
  }

  // ---------------------------------------------------------------- projects

  Future<Project> addProject(String name) async {
    final project = Project(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
    );
    _projects.add(project);
    await _saveProjects();
    return project;
  }

  /// Replaces a project's name, jobs or roles.
  Future<void> updateProject(Project project) async {
    final i = _projects.indexWhere((p) => p.id == project.id);
    if (i < 0) return;
    _projects[i] = project;
    await _saveProjects();
  }

  /// Deletes a project, but only an empty one: removing a project that still
  /// has locations or workers would strand them where nobody can punch.
  Future<bool> removeProject(String id) async {
    if (sitesOf(id).isNotEmpty || workersOf(id).isNotEmpty) return false;
    _projects.removeWhere((p) => p.id == id);
    await _saveProjects();
    return true;
  }

  Future<void> _saveProjects() async {
    await _prefs.setStringList(
      _projectsKey,
      _projects.map((p) => jsonEncode(p.toJson())).toList(),
    );
    notifyListeners();
  }

  Future<void> _saveSites() async {
    await _prefs.setStringList(
      _sitesKey,
      _sites.map((s) => jsonEncode(s.toJson())).toList(),
    );
    notifyListeners();
  }

  // ------------------------------------------------------------------- leave

  /// Every request, newest start date first.
  List<LeaveRequest> get leaves => List.unmodifiable(
        [..._leaves]..sort((a, b) => b.from.compareTo(a.from)),
      );

  /// The approved leave [workerId] is on that [day], if any. Pending and
  /// rejected requests do not make anyone absent.
  LeaveRequest? leaveOn(String workerId, DateTime day) {
    for (final leave in _leaves) {
      if (leave.workerId == workerId &&
          leave.status == LeaveStatus.approved &&
          leave.covers(day)) {
        return leave;
      }
    }
    return null;
  }

  /// Everyone (or just [workerId]) on approved leave that [day].
  List<LeaveRequest> leavesOn(DateTime day, {String? workerId}) => _leaves
      .where((l) =>
          l.status == LeaveStatus.approved &&
          l.covers(day) &&
          (workerId == null || l.workerId == workerId))
      .toList(growable: false);

  /// Day-of-month numbers with approved leave, for anyone or [workerId].
  Set<int> leaveDaysIn(int year, int month, {String? workerId}) {
    final result = <int>{};
    final daysInMonth = DateTime(year, month + 1, 0).day;
    for (var d = 1; d <= daysInMonth; d++) {
      if (leavesOn(DateTime(year, month, d), workerId: workerId).isNotEmpty) {
        result.add(d);
      }
    }
    return result;
  }

  /// Requests still waiting for a supervisor.
  int get pendingLeaveCount =>
      _leaves.where((l) => l.status == LeaveStatus.pending).length;

  /// Whether [workerId] already has pending or approved leave sharing a day
  /// with [from]–[to]. Rejected requests do not block a new one.
  bool hasOverlappingLeave(String workerId, DateTime from, DateTime to) =>
      _leaves.any((l) =>
          l.workerId == workerId &&
          l.status != LeaveStatus.rejected &&
          l.overlaps(from, to));

  /// Files a new pending request. Throws [ArgumentError] when the dates are
  /// backwards and [StateError] when it overlaps leave already asked for —
  /// the screen checks both first, this is the guard behind it.
  Future<LeaveRequest> requestLeave({
    required Worker worker,
    required LeaveType type,
    required DateTime from,
    required DateTime to,
    required String reason,
  }) async {
    final start = dateOnly(from);
    final end = dateOnly(to);
    if (end.isBefore(start)) {
      throw ArgumentError('Leave cannot end before it starts');
    }
    if (hasOverlappingLeave(worker.id, start, end)) {
      throw StateError('${worker.name} already has leave on these days');
    }
    final leave = LeaveRequest(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      workerId: worker.id,
      workerName: worker.name,
      type: type,
      from: start,
      to: end,
      reason: reason.trim(),
      status: LeaveStatus.pending,
      requestedAt: DateTime.now(),
    );
    _leaves.add(leave);
    await _saveLeaves();
    return leave;
  }

  /// Approves or rejects a pending request. Already-decided requests are
  /// left alone, so a stale screen cannot flip a decision.
  Future<void> decideLeave(String id, {required bool approve}) async {
    final i = _leaves.indexWhere((l) => l.id == id);
    if (i < 0 || _leaves[i].status != LeaveStatus.pending) return;
    _leaves[i] = _leaves[i].decided(
      approve ? LeaveStatus.approved : LeaveStatus.rejected,
      DateTime.now(),
    );
    await _saveLeaves();
  }

  Future<void> removeLeave(String id) async {
    _leaves.removeWhere((l) => l.id == id);
    await _saveLeaves();
  }

  Future<void> _saveLeaves() async {
    await _prefs.setStringList(
      _leavesKey,
      _leaves.map((l) => jsonEncode(l.toJson())).toList(),
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

/// One location of a project, right now.
class LocationNow {
  const LocationNow({
    required this.site,
    required this.working,
    required this.onBreak,
    required this.hoursToday,
  });

  final Site site;
  final List<Worker> working;
  final List<Worker> onBreak;

  /// Hours worked here today by anyone, travel and breaks excluded.
  final Duration hoursToday;
}

/// A project's day: see [AttendanceStore.projectToday].
class ProjectToday {
  const ProjectToday({
    required this.locations,
    required this.notIn,
    required this.onLeave,
    this.afterShift = const [],
    required this.totalHours,
    required this.travel,
    required this.late,
    required this.autoCheckouts,
  });

  final List<LocationNow> locations;

  /// On the project, no punch today, not on leave.
  final List<Worker> notIn;
  final List<Worker> onLeave;

  /// Still checked in at a location whose shift has already ended: likely a
  /// forgotten check-out, worth a call before it becomes an auto check-out.
  final List<(Worker, Site)> afterShift;
  final Duration totalHours;
  final Duration travel;
  final int late;
  final int autoCheckouts;

  int get onSite => locations.fold(
      0, (sum, l) => sum + l.working.length + l.onBreak.length);
}

/// One worker's day, for the supervisor's view.
class WorkerDay {
  const WorkerDay({
    this.firstIn,
    this.lastOut,
    this.lateBy = Duration.zero,
    this.worked = Duration.zero,
    this.breaks = Duration.zero,
    this.travel = Duration.zero,
    this.overtime = Duration.zero,
    this.overtimeStatus,
  });

  /// First check-in of the day; null when there was none.
  final DateTime? firstIn;

  /// The day's check-out, when the day ended in one; null while still in.
  final DateTime? lastOut;

  /// How long after the shift start the day began; zero when on time
  /// (within the grace period).
  final Duration lateBy;
  final Duration worked;
  final Duration breaks;
  final Duration travel;
  final Duration overtime;
  final RequestStatus? overtimeStatus;
}

class ShiftFlags {
  const ShiftFlags({
    this.late = false,
    this.overtime = false,
    this.short = false,
    this.autoCheckout = false,
    this.corrected = false,
    this.clockSuspect = false,
  });

  final bool late;
  final bool overtime;
  final bool short;

  /// The app closed a session for this worker that day (they moved location
  /// or forgot to check out). Worth a supervisor's look.
  final bool autoCheckout;

  /// A supervisor-approved correction changed this day.
  final bool corrected;

  /// A punch that day was made with the phone's clock off from GPS time.
  final bool clockSuspect;

  bool get any =>
      late || overtime || short || autoCheckout || corrected || clockSuspect;
}
