import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attendance.dart';
import '../models/leave.dart';
import '../models/project.dart';
import '../models/requests.dart';
import '../services/location_service.dart'
    show geofenceRadiusMeters, haversineMeters;
import 'attendance_database.dart';

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

/// Days of punches kept in memory, counting back from today. Older ones stay
/// in the database: the calendar loads a month on demand
/// ([AttendanceStore.ensureMonthLoaded]), and each worker's newest punch is
/// always kept, however old, so an open session is never missed.
const punchMemoryDays = 35;

/// How long before its start a shift already counts as running, for
/// choosing between projects that share a location: someone arriving at
/// 06:40 for a 07:00 shift is there for that shift.
const earlyCheckIn = Duration(minutes: 30);

/// What a worker may do next at one location, and anything the app has to
/// record first to make it legal.
class PunchPlan {
  const PunchPlan({required this.actions, this.autoClose, this.autoOpen});

  final List<PunchType> actions;

  /// A check-out the app adds before the worker's own punch: it closes a
  /// session left open at another location, or on an earlier day.
  final Punch? autoClose;

  /// A check-in the app adds right after [autoClose], when a worker stayed
  /// on at a location shared by two projects: one project's shift ended and
  /// the other's took over, without anyone punching.
  final Punch? autoOpen;
}

/// Which location a punch belongs to, when the worker stands where several
/// are in range (two projects sharing one place, say).
class SiteChoice {
  const SiteChoice.of(Site this.site) : options = const [];
  const SiteChoice.ask(this.options) : site = null;
  const SiteChoice.none()
      : site = null,
        options = const [];

  /// Decided: punch here.
  final Site? site;

  /// Undecided: shifts here overlap, so the worker picks one of these.
  final List<Site> options;
}

/// Who is using the phone, and so which home screen they get.
///
/// Worker: one person's own phone; the app confirms that one face (1:1).
/// Kiosk: a phone kept at the gate for a team; the app works out which of
/// several enrolled people has walked up (1:N).
/// Supervisor: manages workers, sites, leave and attendance, behind the PIN.
enum AppRole { worker, kiosk, supervisor }

/// Everything the app knows, kept on the device only — no backend, no network.
///
/// Records live in SQLite ([AttendanceDatabase]), one row each, so a punch
/// is one small insert however long the history. Reads are answered from
/// memory: punches are indexed by worker and by day, so "what did this
/// worker do today" is a binary search, not a walk through every punch.
/// Small settings (language, role, the phone's owner) stay in
/// `shared_preferences`.
class AttendanceStore extends ChangeNotifier {
  AttendanceStore._(
    this._prefs,
    this._db,
    this._sites,
    this._workers,
    this._leaves,
    this._projects,
    this._overtime,
    this._corrections,
    this._languageCode,
    this._lastRole,
    this._activeWorkerId,
    this._loadedFromDay,
    this._todayKey,
  );

  // Record kinds in the database; the first five are also the old
  // shared_preferences keys they are imported from.
  static const _sitesKey = 'sites';
  static const _workersKey = 'workers';
  static const _leavesKey = 'leaves';
  static const _projectsKey = 'projects';
  static const _overtimeKey = 'overtime';
  static const _correctionsKey = 'corrections';
  static const _punchesKey = 'punches';

  static const _languageKey = 'language';
  static const _roleKey = 'role';
  static const _activeWorkerKey = 'activeWorker';
  static const _importedMeta = 'importedPrefs';

  final SharedPreferences _prefs;
  final AttendanceDatabase _db;
  final List<Site> _sites;
  final List<Worker> _workers;
  final List<LeaveRequest> _leaves;
  final List<Project> _projects;
  final List<OvertimeDecision> _overtime;
  final List<CorrectionRequest> _corrections;
  String _languageCode;
  AppRole? _lastRole;
  String? _activeWorkerId;

  // ------------------------------------------------------- punches in memory

  /// Each worker's punches in time order; the last one is their newest.
  final Map<String, List<Punch>> _byWorker = {};

  /// Each day's punches (key from [dayKeyOf]) in time order.
  final Map<int, List<Punch>> _byDay = {};

  /// Days from here on are complete in memory.
  int _loadedFromDay;

  /// Older months (`yyyymm`) the calendar has loaded.
  final Set<int> _loadedMonths = {};

  /// The day the window was last moved for; see [_moveWindow].
  int _todayKey;

  DateTime? _newest;

  /// Bumped on every change; caches compare against it.
  int _version = 0;

  static Future<AttendanceStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final db = await AttendanceDatabase.openDefault();
    await _importFromPreferences(prefs, db);

    var sites = db.records(_sitesKey).map(Site.fromJson).toList();
    var workers = db.records(_workersKey).map(Worker.fromJson).toList();
    final projects = db.records(_projectsKey).map(Project.fromJson).toList();

    // Sites and workers saved before projects existed belong to no project,
    // and so could never punch. They move into "General" once, and are saved
    // back, so nothing recorded before is lost.
    if (sites.any((s) => s.projectId.isEmpty) ||
        workers.any((w) => w.projectId.isEmpty)) {
      db.transaction(() {
        if (!projects.any((p) => p.id == generalProjectId)) {
          const general = Project(id: generalProjectId, name: 'General');
          projects.add(general);
          db.putRecord(_projectsKey, general.id, general.toJson());
        }
        sites = [
          for (final s in sites)
            if (s.projectId.isEmpty)
              s.copyWith(projectId: generalProjectId)
            else
              s,
        ];
        workers = [
          for (final w in workers)
            if (w.projectId.isEmpty)
              w.copyWith(projectId: generalProjectId)
            else
              w,
        ];
        for (final s in sites) {
          db.putRecord(_sitesKey, s.id, s.toJson());
        }
        for (final w in workers) {
          db.putRecord(_workersKey, w.id, w.toJson());
        }
      });
    }

    final now = DateTime.now();
    final store = AttendanceStore._(
      prefs,
      db,
      sites,
      workers,
      db.records(_leavesKey).map(LeaveRequest.fromJson).toList(),
      projects,
      db.records(_overtimeKey).map(OvertimeDecision.fromJson).toList(),
      db.records(_correctionsKey).map(CorrectionRequest.fromJson).toList(),
      prefs.getString(_languageKey) ?? 'en',
      _parseRole(prefs.getString(_roleKey)),
      prefs.getString(_activeWorkerKey),
      _windowStart(now),
      dayKeyOf(now),
    );

    // Recent days in full; anything older only as each worker's newest
    // punch, which is all [planAt] and [statusOf] need.
    for (final p in db.punchesBetweenDays(store._loadedFromDay, 99991231)) {
      store._index(p);
    }
    for (final p in db.latestPunchPerWorker()) {
      if (dayKeyOf(p.at) < store._loadedFromDay) store._index(p);
    }
    return store;
  }

  static int _windowStart(DateTime now) => dayKeyOf(
      DateTime(now.year, now.month, now.day - punchMemoryDays));

  /// Moves anything saved by older versions of the app (one JSON list per
  /// kind in `shared_preferences`) into the database, once, then removes it
  /// from preferences.
  static Future<void> _importFromPreferences(
    SharedPreferences prefs,
    AttendanceDatabase db,
  ) async {
    const kinds = [
      _punchesKey,
      _sitesKey,
      _workersKey,
      _leavesKey,
      _projectsKey,
      _overtimeKey,
      _correctionsKey,
    ];
    final present = kinds.where(prefs.containsKey).toList();
    if (present.isEmpty) return;

    // The marker is written in the same transaction, so an app killed
    // between this and removing the keys does not import twice.
    if (db.meta(_importedMeta) == null) {
      List<Map<String, dynamic>> read(String key) => [
            for (final e in prefs.getStringList(key) ?? const <String>[])
              jsonDecode(e) as Map<String, dynamic>,
          ];
      db.transaction(() {
        final punches = read(_punchesKey).map(Punch.fromJson).toList()
          ..sort((a, b) => a.at.compareTo(b.at));
        punches.forEach(db.insertPunch);
        for (final kind in kinds.skip(1)) {
          for (final json in read(kind)) {
            db.putRecord(kind, _recordId(kind, json), json);
          }
        }
        db.setMeta(_importedMeta, DateTime.now().toIso8601String());
      });
    }
    for (final key in present) {
      await prefs.remove(key);
    }
  }

  static String _recordId(String kind, Map<String, dynamic> json) =>
      kind == _overtimeKey
          ? _overtimeId(OvertimeDecision.fromJson(json))
          : json['id'] as String;

  static String _overtimeId(OvertimeDecision d) =>
      '${d.workerId}|${dayKeyOf(d.date)}';

  /// Only worker and kiosk are ever restored, so reopening the app can never
  /// land in the supervisor screens without the PIN.
  static AppRole? _parseRole(String? name) => switch (name) {
        'worker' => AppRole.worker,
        'kiosk' => AppRole.kiosk,
        _ => null,
      };

  // ------------------------------------------------------------ saving

  /// True inside [batch]: listeners hear about it once, at the end.
  bool _batching = false;

  /// Runs [body] as one database transaction, with listeners told once at
  /// the end — for bulk changes such as loading demo data.
  Future<void> batch(Future<void> Function() body) async {
    _db.begin();
    _batching = true;
    try {
      await body();
    } finally {
      _batching = false;
      _db.commit();
      notifyListeners();
    }
  }

  void _changed() {
    _version++;
    _leavesByWorker = null;
    if (!_batching) notifyListeners();
  }

  /// Deletes everything recorded for [workerIds] — punches, leave,
  /// corrections and overtime decisions — but not the workers themselves.
  Future<void> removeRecordsOf(Set<String> workerIds) async {
    _db.transaction(() {
      for (final id in workerIds) {
        _db.deletePunchesOf(id);
      }
      for (final l in _leaves.where((l) => workerIds.contains(l.workerId))) {
        _db.deleteRecord(_leavesKey, l.id);
      }
      for (final c
          in _corrections.where((c) => workerIds.contains(c.workerId))) {
        _db.deleteRecord(_correctionsKey, c.id);
      }
      for (final d in _overtime.where((d) => workerIds.contains(d.workerId))) {
        _db.deleteRecord(_overtimeKey, _overtimeId(d));
      }
    });
    for (final id in workerIds) {
      final punches = _byWorker.remove(id);
      if (punches == null) continue;
      for (final p in punches) {
        _byDay[dayKeyOf(p.at)]?.remove(p);
      }
    }
    _byDay.removeWhere((_, list) => list.isEmpty);
    _recomputeNewest();
    _leaves.removeWhere((l) => workerIds.contains(l.workerId));
    _corrections.removeWhere((c) => workerIds.contains(c.workerId));
    _overtime.removeWhere((d) => workerIds.contains(d.workerId));
    _changed();
  }

  // ------------------------------------------------------------ punch index

  /// First position in [list] whose punch is later than [at]: inserting
  /// there keeps time order, after any punch at the same moment.
  static int _after(List<Punch> list, DateTime at) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].at.isAfter(at)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// First position in [list] whose punch is not earlier than [at].
  static int _notBefore(List<Punch> list, DateTime at) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].at.isBefore(at)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _index(Punch p) {
    final mine = _byWorker.putIfAbsent(p.workerId, () => []);
    mine.insert(_after(mine, p.at), p);
    final day = _byDay.putIfAbsent(dayKeyOf(p.at), () => []);
    day.insert(_after(day, p.at), p);
    final newest = _newest;
    if (newest == null || p.at.isAfter(newest)) _newest = p.at;
  }

  void _unindex(Punch p) {
    final mine = _byWorker[p.workerId];
    mine?.remove(p);
    if (mine != null && mine.isEmpty) _byWorker.remove(p.workerId);
    final key = dayKeyOf(p.at);
    final day = _byDay[key];
    day?.remove(p);
    if (day != null && day.isEmpty) _byDay.remove(key);
    if (p.at == _newest) _recomputeNewest();
  }

  bool _isIndexed(Punch p) {
    final mine = _byWorker[p.workerId];
    if (mine == null) return false;
    for (var i = _notBefore(mine, p.at);
        i < mine.length && mine[i].at == p.at;
        i++) {
      if (mine[i].type == p.type) return true;
    }
    return false;
  }

  void _recomputeNewest() {
    DateTime? newest;
    for (final list in _byWorker.values) {
      final at = list.last.at;
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    _newest = newest;
  }

  /// On the first change of a new day, drops days that have left the
  /// memory window (they stay in the database), so a gate phone left
  /// running for weeks does not keep growing. Each worker's newest punch
  /// stays.
  void _moveWindow() {
    final now = DateTime.now();
    final today = dayKeyOf(now);
    if (today <= _todayKey) return;
    _todayKey = today;
    final from = _windowStart(now);
    if (from <= _loadedFromDay && _loadedMonths.isEmpty) return;
    _loadedFromDay = from;
    _loadedMonths.clear();
    _byDay.removeWhere((key, _) => key < from);
    for (final list in _byWorker.values) {
      final newest = list.last;
      list.removeWhere((p) => !identical(p, newest) && dayKeyOf(p.at) < from);
    }
    // A newest punch kept from an old day is that day's only entry.
    for (final list in _byWorker.values) {
      final p = list.last;
      final key = dayKeyOf(p.at);
      if (key < from) {
        final day = _byDay[key] ??= [];
        day.insert(_after(day, p.at), p);
      }
    }
  }

  bool _dayLoaded(int key) =>
      key >= _loadedFromDay || _loadedMonths.contains(key ~/ 100);

  /// Loads a month older than the memory window, for the calendar. Returns
  /// whether anything had to be read. Cheap when already in memory.
  bool ensureMonthLoaded(int year, int month) {
    final monthKey = year * 100 + month;
    final first = monthKey * 100 + 1;
    if (first >= _loadedFromDay || _loadedMonths.contains(monthKey)) {
      return false;
    }
    final last = monthKey * 100 + 31;
    final to = last < _loadedFromDay ? last : _loadedFromDay - 1;
    for (final p in _db.punchesBetweenDays(first, to)) {
      if (!_isIndexed(p)) _index(p);
    }
    _loadedMonths.add(monthKey);
    _version++;
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------ simple reads

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

  /// Everyone on [projectId], including those also on other projects.
  List<Worker> workersOf(String projectId) =>
      _workers.where((w) => w.isOn(projectId)).toList(growable: false);

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

  List<Punch> punchesFor(String workerId, DateTime day) {
    final mine = _byWorker[workerId];
    if (mine == null) return const [];
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final from = _notBefore(mine, start);
    final to = _notBefore(mine, end);
    return from == to ? const [] : mine.sublist(from, to);
  }

  Punch? lastPunchFor(String workerId) => _byWorker[workerId]?.last;

  WorkerStatus statusOf(String workerId) => switch (lastPunchFor(workerId)?.type) {
        PunchType.checkIn || PunchType.breakEnd => WorkerStatus.working,
        PunchType.breakStart => WorkerStatus.onBreak,
        _ => WorkerStatus.off,
      };

  /// Whether [worker] may punch at [site]: only at the locations of their
  /// own projects, so hours can never land on a project they are not on.
  bool canPunchAt(Worker worker, Site site) => worker.isOn(site.projectId);

  /// Two locations at the same place: within one check-in circle of each
  /// other. Typically one place used by two projects, each with its own
  /// location record and shift.
  static bool samePlace(Site a, Site b) =>
      haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude) <=
      geofenceRadiusMeters;

  /// Whether [site]'s shift is running at [at], counting [earlyCheckIn].
  static bool shiftRunning(Site site, DateTime at) =>
      !at.isBefore(site.shiftStartOn(at).subtract(earlyCheckIn)) &&
      at.isBefore(site.shiftEndOn(at));

  /// Which of the locations in range ([here]) [worker]'s punch at [now]
  /// belongs to. Only their own projects' locations count; with several,
  /// the shift decides:
  /// - already on the clock at one of them: that one, unless its shift has
  ///   ended and another project's shift here is running (then that one,
  ///   and [planAt] hands the session over at the shift end);
  /// - otherwise the one whose shift is running;
  /// - two running at once (overlapping shifts): the worker is asked;
  /// - none running: the one whose shift is nearest in time.
  SiteChoice siteFor(Worker worker, List<Site> here, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final mine = here.where((s) => canPunchAt(worker, s)).toList();
    if (mine.isEmpty) return const SiteChoice.none();
    if (mine.length == 1) return SiteChoice.of(mine.first);

    SiteChoice pick(List<Site> sites) =>
        sites.length == 1 ? SiteChoice.of(sites.first) : SiteChoice.ask(sites);

    final last = lastPunchFor(worker.id);
    final open = last != null &&
            last.type != PunchType.checkOut &&
            _isSameDay(last.at, at)
        ? mine.where((s) => s.id == last.siteId).firstOrNull
        : null;
    if (open != null) {
      if (at.isBefore(open.shiftEndOn(at))) return SiteChoice.of(open);
      final takingOver = [
        for (final s in mine)
          if (s.id != open.id && shiftRunning(s, at)) s,
      ];
      return takingOver.isEmpty ? SiteChoice.of(open) : pick(takingOver);
    }

    final running = mine.where((s) => shiftRunning(s, at)).toList();
    if (running.isNotEmpty) return pick(running);

    Duration gap(Site s) {
      final start = s.shiftStartOn(at).difference(at).abs();
      final end = s.shiftEndOn(at).difference(at).abs();
      return start < end ? start : end;
    }

    final nearest = [...mine]..sort((a, b) => gap(a).compareTo(gap(b)));
    final best = gap(nearest.first);
    return pick([
      for (final s in nearest)
        if (gap(s) == best) s,
    ]);
  }

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
  ///   day, then check in, so a forgotten check-out never adds whole nights;
  /// - open at another project's location at the same place, whose shift
  ///   has ended: closed at that shift end and opened here at the same
  ///   moment ([PunchPlan.autoOpen]), so the hours split between the two
  ///   projects; then check out or break here.
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

    Punch closing(DateTime at) => Punch(
          type: PunchType.checkOut,
          at: at,
          workerId: last.workerId,
          employeeId: last.employeeId,
          workerName: last.workerName,
          siteId: last.siteId,
          siteName: last.siteName,
          latitude: openSite?.latitude ?? last.latitude,
          longitude: openSite?.longitude ?? last.longitude,
          distanceMeters: 0,
          auto: true,
        );

    // Stayed on at a shared place past the first project's shift.
    final handoverAt = openSite?.shiftEndOn(at);
    if (!earlierDay &&
        openSite != null &&
        handoverAt != null &&
        openSite.projectId != site.projectId &&
        samePlace(openSite, site) &&
        handoverAt.isAfter(last.at) &&
        !handoverAt.isAfter(at)) {
      return PunchPlan(
        actions: const [PunchType.checkOut, PunchType.breakStart],
        autoClose: closing(handoverAt),
        autoOpen: Punch(
          type: PunchType.checkIn,
          at: handoverAt,
          workerId: last.workerId,
          employeeId: last.employeeId,
          workerName: last.workerName,
          siteId: site.id,
          siteName: site.name,
          latitude: site.latitude,
          longitude: site.longitude,
          distanceMeters: 0,
          auto: true,
        ),
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
      autoClose: closing(closeAt),
    );
  }

  /// Estimated travel time between two locations: straight-line distance at
  /// [travelSpeedMetersPerSecond]. An estimate, shown as such.
  static Duration travelBetween(Site from, Site to) {
    final meters = haversineMeters(
        from.latitude, from.longitude, to.latitude, to.longitude);
    return Duration(seconds: (meters / travelSpeedMetersPerSecond).round());
  }

  /// How [workerId]'s session open right now was made: on their own phone
  /// or at a gate phone. Null when they are not checked in today (a session
  /// left open on an earlier day is closed by the next check-in, whichever
  /// way that comes), or when only the app or a supervisor touched it.
  ///
  /// The session runs back to the last check-out the worker made; the app's
  /// automatic check-outs (moving location, shift handover) do not end it.
  PunchVia? openSessionVia(String workerId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final last = lastPunchFor(workerId);
    if (last == null ||
        last.type == PunchType.checkOut ||
        !_isSameDay(last.at, at)) {
      return null;
    }
    final today = punchesFor(workerId, at);
    for (var i = today.length - 1; i >= 0; i--) {
      final p = today[i];
      if (p.type == PunchType.checkOut && !p.auto) break;
      if (p.via != null) return p.via;
    }
    return null;
  }

  /// Whether [workerId] may punch [via] this way now: always, unless they are
  /// checked in the other way. One session, one way, until they check out.
  bool viaAllowed(String workerId, PunchVia via, {DateTime? now}) {
    final open = openSessionVia(workerId, now: now);
    return open == null || open == via;
  }

  /// Saves the worker's own [punch], after anything [plan] needs first, as
  /// one write. Throws [StateError] for a punch made the other way while a
  /// session is open (see [viaAllowed]); the screens check first.
  Future<void> recordPunch(PunchPlan plan, Punch punch) async {
    final via = punch.via;
    if (via != null && !viaAllowed(punch.workerId, via, now: punch.at)) {
      throw StateError('${punch.workerName} is checked in the other way');
    }
    final all = [
      for (final p in [?plan.autoClose, ?plan.autoOpen, punch]) _withId(p),
    ];
    _db.transaction(() => all.forEach(_db.insertPunch));
    _moveWindow();
    all.forEach(_index);
    _changed();
  }

  /// Hours [workerId] worked at [projectId]'s locations on [day].
  Duration workedOnProject(String workerId, String projectId, DateTime day) {
    var total = Duration.zero;
    workedBySiteIdOn(workerId, day).forEach((siteId, hours) {
      if (siteById(siteId)?.projectId == projectId) total += hours;
    });
    return total;
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
  }) =>
      _span(punchesFor(workerId, day), day, counting: counting);

  static Duration _span(
    List<Punch> punches,
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

    for (final punch in punches) {
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
    final elsewhere = <(Worker, Site)>[];
    final ownSites = {for (final s in sitesOf(projectId)) s.id};
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
      final site = openToday ? siteById(last.siteId) : null;
      if (openToday && !ownSites.contains(last.siteId)) {
        // On the clock, but for another of their projects.
        if (site != null) elsewhere.add((w, site));
      } else if (openToday) {
        (last.type == PunchType.breakStart ? onBreak : working)
            .putIfAbsent(last.siteId, () => [])
            .add(w);
        if (site != null && at.isAfter(site.shiftEndOn(at))) {
          afterShift.add((w, site));
        }
      } else if (leaveOn(w.id, at) != null) {
        onLeave.add(w);
      } else if (punchesFor(w.id, at).isEmpty) {
        notIn.add(w);
      }

      // Only hours at this project's locations count here.
      workedBySiteIdOn(w.id, at).forEach((siteId, d) {
        if (!ownSites.contains(siteId)) return;
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
      elsewhere: elsewhere,
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
    final worked = _span(punches, day, counting: WorkerStatus.working);

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

  (int, int)? _pendingKey;
  List<(Worker, DateTime)> _pending = const [];

  /// Days with overtime still to decide, newest first. Only finished days:
  /// overtime still growing today is decided once the worker checks out.
  /// Covers the last [punchMemoryDays] days; an older day left undecided is
  /// still in the database but no longer asks for a decision.
  ///
  /// Kept until something changes (or the day does): the supervisor home
  /// asks for the count every second.
  List<(Worker, DateTime)> get pendingOvertime {
    final key = (_version, dayKeyOf(DateTime.now()));
    if (key == _pendingKey) return _pending;
    final decided = {for (final d in _overtime) _overtimeId(d)};
    final result = <(Worker, DateTime)>[];
    for (final worker in _workers) {
      final mine = _byWorker[worker.id];
      if (mine == null) continue;
      var from = 0;
      while (from < mine.length) {
        final at = mine[from].at;
        final day = DateTime(at.year, at.month, at.day);
        final dayKey = dayKeyOf(at);
        var to = from + 1;
        while (to < mine.length && _isSameDay(mine[to].at, day)) {
          to++;
        }
        if (dayKey >= _loadedFromDay &&
            !decided.contains('${worker.id}|$dayKey')) {
          final punches = mine.sublist(from, to);
          if (_dayOver(punches, day) &&
              _span(punches, day, counting: WorkerStatus.working) >
                  standardDay) {
            result.add((worker, day));
          }
        }
        from = to;
      }
    }
    result.sort((a, b) => b.$2.compareTo(a.$2));
    _pendingKey = key;
    return _pending = List.unmodifiable(result);
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
    final decision = OvertimeDecision(
      workerId: workerId,
      date: DateTime(day.year, day.month, day.day),
      approved: approve,
      minutes: approve ? overtimeOn(workerId, day).inMinutes : 0,
      decidedAt: DateTime.now(),
    );
    _db.putRecord(_overtimeKey, _overtimeId(decision), decision.toJson());
    _overtime.add(decision);
    _changed();
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
    final newest = _newest;
    if (newest == null) return false;
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
    _db.putRecord(_correctionsKey, request.id, request.toJson());
    _corrections.add(request);
    _changed();
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
      final rejected = request.decided(RequestStatus.rejected, DateTime.now());
      _db.putRecord(_correctionsKey, rejected.id, rejected.toJson());
      _corrections[i] = rejected;
      _changed();
      return;
    }

    // The whole day must be in memory to judge it.
    ensureMonthLoaded(request.at.year, request.at.month);
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
      id: newPunchId(),
      // Lets a server that already has the replaced punch set it aside.
      replaces: replaced?.id,
    );

    final after = [
      for (final p in day)
        if (!identical(p, replaced)) p,
      corrected,
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (!validDay(after)) {
      throw StateError('This correction does not fit the punches of that day');
    }

    final approved = request.decided(
      RequestStatus.approved,
      DateTime.now(),
      replacedAt: replaced?.at,
      replacedAuto: replaced?.auto ?? false,
    );
    _db.transaction(() {
      if (replaced != null) _db.deletePunch(replaced);
      _db.insertPunch(corrected);
      _db.putRecord(_correctionsKey, approved.id, approved.toJson());
    });
    if (replaced != null) _unindex(replaced);
    _index(corrected);
    _corrections[i] = approved;
    _changed();
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

  // ------------------------------------------------------------- whole day

  // Passing [workerId] narrows any of these to that one person, which is how
  // a worker's own calendar shows only their own days.

  List<Punch> punchesOn(DateTime day, {String? workerId}) {
    if (workerId != null) return punchesFor(workerId, day);
    final all = _byDay[dayKeyOf(day)];
    return all == null ? const [] : List.of(all, growable: false);
  }

  (int, int?)? _monthCacheVersion;
  final Map<(int, String?), Duration> _dayTotals = {};

  /// Day-of-month to hours worked, for the calendar grid. Days before the
  /// memory window count only once their month is loaded
  /// ([ensureMonthLoaded]).
  Map<int, Duration> monthTotals(int year, int month, {String? workerId}) {
    // Past days do not change until a punch does; only today is live.
    final today = dayKeyOf(DateTime.now());
    if (_monthCacheVersion != (_version, today)) {
      _dayTotals.clear();
      _monthCacheVersion = (_version, today);
    }
    final people = workerId == null ? null : {workerId};
    final result = <int, Duration>{};
    final daysInMonth = DateTime(year, month + 1, 0).day;
    for (var d = 1; d <= daysInMonth; d++) {
      final key = year * 10000 + month * 100 + d;
      final punches = _byDay[key];
      if (punches == null || !_dayLoaded(key)) continue;
      if (people != null && !punches.any((p) => people.contains(p.workerId))) {
        continue;
      }
      final day = DateTime(year, month, d);
      Duration compute() {
        final ids = {
          for (final p in punches)
            if (people == null || people.contains(p.workerId)) p.workerId,
        };
        var total = Duration.zero;
        for (final id in ids) {
          // Punches of workers since removed still count, as before.
          total += workedOn(id, day);
        }
        return total;
      }

      result[d] = key == today
          ? compute()
          : _dayTotals.putIfAbsent((key, workerId), compute);
    }
    return result;
  }

  Duration monthTotal(int year, int month, {String? workerId}) =>
      monthTotals(year, month, workerId: workerId)
          .values
          .fold(Duration.zero, (sum, d) => sum + d);

  // ------------------------------------------------------------------ writes

  Future<void> add(Punch punch) async {
    final saved = _withId(punch);
    _db.insertPunch(saved);
    _moveWindow();
    _index(saved);
    _changed();
  }

  /// Every saved punch has a permanent id, made here on the phone.
  static Punch _withId(Punch p) => p.id == null ? p.withId(newPunchId()) : p;

  // ------------------------------------------------------------------ outbox

  /// Punches not yet sent to a server, oldest first. Only the connected
  /// app reads these; the demo app never sends anything.
  List<Punch> punchesToSend({int limit = 200}) => _db.punchesToSend(limit);

  int get punchesToSendCount => _db.punchesToSendCount;

  /// Sent punches whose state is [AttendanceDatabase.uploaded],
  /// [AttendanceDatabase.refused] or [AttendanceDatabase.keptOnPhone].
  int punchesSentAs(int state) => _db.countInState(state);

  void markSent(Iterable<String> ids, int state) => _db.markSent(ids, state);

  Future<void> addWorker(Worker worker) async {
    _db.putRecord(_workersKey, worker.id, worker.toJson());
    _workers.add(worker);
    _changed();
  }

  /// Puts [workerId] on [projectId] with a role and job, or changes their
  /// role and job there. Their other projects stay: a worker may be on
  /// several, with a role and job on each.
  Future<void> assignWorker(
    String workerId, {
    required String projectId,
    required String role,
    required String job,
  }) async {
    final i = _workers.indexWhere((w) => w.id == workerId);
    if (i < 0) return;
    _replaceWorker(
        i, _workers[i].withAssignment(projectId, role: role, job: job));
  }

  /// Takes [workerId] off [projectId]; hours already worked there stay.
  /// False (and nothing changes) when it is their only project.
  Future<bool> unassignWorker(String workerId, String projectId) async {
    final i = _workers.indexWhere((w) => w.id == workerId);
    if (i < 0) return false;
    final updated = _workers[i].withoutProject(projectId);
    if (updated == null) return false;
    _replaceWorker(i, updated);
    return true;
  }

  void _replaceWorker(int i, Worker updated) {
    _db.putRecord(_workersKey, updated.id, updated.toJson());
    _workers[i] = updated;
    _changed();
  }

  Future<void> removeWorker(String id) async {
    _db.deleteRecord(_workersKey, id);
    _workers.removeWhere((w) => w.id == id);
    _changed();
  }

  Future<void> addSite(Site site) async {
    _db.putRecord(_sitesKey, site.id, site.toJson());
    _sites.add(site);
    _changed();
  }

  Future<void> removeSite(String id) async {
    _db.deleteRecord(_sitesKey, id);
    _sites.removeWhere((s) => s.id == id);
    _changed();
  }

  /// Changes a location's shift. Throws [ArgumentError] when it would end
  /// before it starts (overnight shifts are not supported yet).
  Future<void> setShift(String siteId, int startMinutes, int endMinutes) async {
    if (endMinutes <= startMinutes) {
      throw ArgumentError('Shift must end after it starts');
    }
    final i = _sites.indexWhere((s) => s.id == siteId);
    if (i < 0) return;
    final updated = _sites[i]
        .copyWith(shiftStartMinutes: startMinutes, shiftEndMinutes: endMinutes);
    _db.putRecord(_sitesKey, updated.id, updated.toJson());
    _sites[i] = updated;
    _changed();
  }

  // ---------------------------------------------------------------- projects

  Future<Project> addProject(String name, {String? id}) async {
    final project = Project(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
    );
    _db.putRecord(_projectsKey, project.id, project.toJson());
    _projects.add(project);
    _changed();
    return project;
  }

  /// Replaces a project's name, jobs or roles.
  Future<void> updateProject(Project project) async {
    final i = _projects.indexWhere((p) => p.id == project.id);
    if (i < 0) return;
    _db.putRecord(_projectsKey, project.id, project.toJson());
    _projects[i] = project;
    _changed();
  }

  /// Deletes a project, but only an empty one: removing a project that still
  /// has locations or workers would strand them where nobody can punch.
  Future<bool> removeProject(String id) async {
    if (sitesOf(id).isNotEmpty || workersOf(id).isNotEmpty) return false;
    _db.deleteRecord(_projectsKey, id);
    _projects.removeWhere((p) => p.id == id);
    _changed();
    return true;
  }

  // ------------------------------------------------------------------- leave

  /// Every request, newest start date first.
  List<LeaveRequest> get leaves => List.unmodifiable(
        [..._leaves]..sort((a, b) => b.from.compareTo(a.from)),
      );

  /// Approved leave by worker; rebuilt after any change, because the
  /// boards ask for every worker on every tick.
  Map<String, List<LeaveRequest>>? _leavesByWorker;

  Map<String, List<LeaveRequest>> get _approvedLeave {
    final cached = _leavesByWorker;
    if (cached != null) return cached;
    final map = <String, List<LeaveRequest>>{};
    for (final l in _leaves) {
      if (l.status == LeaveStatus.approved) {
        (map[l.workerId] ??= []).add(l);
      }
    }
    return _leavesByWorker = map;
  }

  /// The approved leave [workerId] is on that [day], if any. Pending and
  /// rejected requests do not make anyone absent.
  LeaveRequest? leaveOn(String workerId, DateTime day) {
    for (final leave in _approvedLeave[workerId] ?? const <LeaveRequest>[]) {
      if (leave.covers(day)) return leave;
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
    _db.putRecord(_leavesKey, leave.id, leave.toJson());
    _leaves.add(leave);
    _changed();
    return leave;
  }

  /// Approves or rejects a pending request. Already-decided requests are
  /// left alone, so a stale screen cannot flip a decision.
  Future<void> decideLeave(String id, {required bool approve}) async {
    final i = _leaves.indexWhere((l) => l.id == id);
    if (i < 0 || _leaves[i].status != LeaveStatus.pending) return;
    final decided = _leaves[i].decided(
      approve ? LeaveStatus.approved : LeaveStatus.rejected,
      DateTime.now(),
    );
    _db.putRecord(_leavesKey, decided.id, decided.toJson());
    _leaves[i] = decided;
    _changed();
  }

  Future<void> removeLeave(String id) async {
    _db.deleteRecord(_leavesKey, id);
    _leaves.removeWhere((l) => l.id == id);
    _changed();
  }

  Future<void> clearPunches() async {
    _db.deleteAllPunches();
    _byWorker.clear();
    _byDay.clear();
    _loadedMonths.clear();
    _newest = null;
    _changed();
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
    this.elsewhere = const [],
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

  /// On this project too, but on the clock right now at a location of
  /// another of their projects.
  final List<(Worker, Site)> elsewhere;
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
