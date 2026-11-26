import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance.dart';
import '../models/leave.dart';
import '../models/project.dart';
import '../services/location_service.dart' show haversineMeters;

/// Standard day, whatever the locations' shifts: anything past this is
/// overtime (the UAE limit is 8 hours a day).
const standardDay = Duration(hours: 8);

/// How late after a location's shift start still counts as on time.
const lateGrace = Duration(minutes: 10);

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
    this._languageCode,
    this._lastRole,
    this._activeWorkerId,
  );

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

    return AttendanceStore._(
      prefs,
      punches,
      sites,
      workers,
      leaves,
      projects,
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
    if (auto != null) _punches.add(auto);
    _punches.add(punch);
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

    final firstIn = punches.firstWhere(
      (p) => p.type == PunchType.checkIn,
      orElse: () => punches.first,
    );
    // Late is judged against the shift of the location the day started at.
    final firstSite = siteById(firstIn.siteId);
    final shiftStart = firstSite?.shiftStartOn(day) ??
        DateTime(day.year, day.month, day.day)
            .add(const Duration(minutes: Site.defaultShiftStart));
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
      autoCheckout: punches.any((p) => p.auto),
    );
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
    _punches.add(punch);
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
    required this.totalHours,
    required this.travel,
    required this.late,
    required this.autoCheckouts,
  });

  final List<LocationNow> locations;

  /// On the project, no punch today, not on leave.
  final List<Worker> notIn;
  final List<Worker> onLeave;
  final Duration totalHours;
  final Duration travel;
  final int late;
  final int autoCheckouts;

  int get onSite => locations.fold(
      0, (sum, l) => sum + l.working.length + l.onBreak.length);
}

class ShiftFlags {
  const ShiftFlags({
    this.late = false,
    this.overtime = false,
    this.short = false,
    this.autoCheckout = false,
  });

  final bool late;
  final bool overtime;
  final bool short;

  /// The app closed a session for this worker that day (they moved location
  /// or forgot to check out). Worth a supervisor's look.
  final bool autoCheckout;

  bool get any => late || overtime || short || autoCheckout;
}
