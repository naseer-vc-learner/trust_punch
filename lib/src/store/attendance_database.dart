import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/attendance.dart';

/// `20270304` for 4 March 2027, in local time: the day a punch belongs to.
int dayKeyOf(DateTime at) => at.year * 10000 + at.month * 100 + at.day;

/// Where the store keeps what must survive a restart: one row per punch
/// and one row per worker, site, project, leave, correction and overtime
/// decision.
///
/// A punch is one small insert, whatever is already recorded. The old
/// `shared_preferences` storage rewrote the whole history on every punch,
/// which a gate doing thousands a day cannot afford.
///
/// Synchronous on purpose (SQLite through `dart:ffi`): writes in WAL mode
/// take microseconds, and the store keeps its synchronous read API. Data is
/// not encrypted, same as before; it sits in the app's private folder.
class AttendanceDatabase {
  AttendanceDatabase._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    // Durable against an app crash; a power cut may lose the last moments,
    // which is the usual trade-off for WAL on phones.
    _db.execute('PRAGMA synchronous = NORMAL');
    // Deleted rows are overwritten, not left readable in free pages, so
    // "Delete all attendance" and removed workers really are gone. Costs
    // only on deletes, which are rare.
    _db.execute('PRAGMA secure_delete = ON');
    _migrate();
    _insertPunch = _db.prepare(
      'INSERT INTO punches (worker_id, at, day, type, employee_id, '
      'worker_name, site_id, site_name, lat, lng, distance, flags, photo) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      persistent: true,
    );
    _upsertRecord = _db.prepare(
      'INSERT INTO records (kind, id, json) VALUES (?, ?, ?) '
      'ON CONFLICT (kind, id) DO UPDATE SET json = excluded.json',
      persistent: true,
    );
  }

  /// A database file at [path], created if missing.
  factory AttendanceDatabase.open(String path) =>
      AttendanceDatabase._(sqlite3.open(path));

  /// Gone when closed; for tests.
  factory AttendanceDatabase.inMemory() =>
      AttendanceDatabase._(sqlite3.openInMemory());

  static AttendanceDatabase? _debugOverride;

  /// Makes [openDefault] return [database] (tests have no app folder).
  static void debugUse(AttendanceDatabase? database) =>
      _debugOverride = database;

  /// The app's database in its private support folder.
  static Future<AttendanceDatabase> openDefault() async {
    final override = _debugOverride;
    if (override != null) return override;
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return AttendanceDatabase.open('${dir.path}${Platform.pathSeparator}'
        'attendance.db');
  }

  final Database _db;
  late final PreparedStatement _insertPunch;
  late final PreparedStatement _upsertRecord;

  static const schemaVersion = 1;

  void _migrate() {
    if (_db.userVersion >= schemaVersion) return;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS punches (
        id INTEGER PRIMARY KEY,
        worker_id TEXT NOT NULL,
        at INTEGER NOT NULL,
        day INTEGER NOT NULL,
        type TEXT NOT NULL,
        employee_id TEXT NOT NULL,
        worker_name TEXT NOT NULL,
        site_id TEXT NOT NULL,
        site_name TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        distance REAL NOT NULL,
        flags INTEGER NOT NULL,
        photo TEXT
      );
      CREATE INDEX IF NOT EXISTS punches_worker_at ON punches (worker_id, at);
      CREATE INDEX IF NOT EXISTS punches_day ON punches (day);
      CREATE TABLE IF NOT EXISTS records (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE (kind, id)
      );
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db.userVersion = schemaVersion;
  }

  // ------------------------------------------------------------ transactions

  int _depth = 0;

  /// Runs [body] as one transaction: all of it is saved, or none. Nested
  /// calls join the outer one.
  T transaction<T>(T Function() body) {
    if (_depth > 0) {
      _depth++;
      try {
        return body();
      } finally {
        _depth--;
      }
    }
    _db.execute('BEGIN');
    _depth = 1;
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _depth = 0;
    }
  }

  /// Opens a transaction that stays open until [commit]; for the store's
  /// `batch`, whose body is asynchronous.
  void begin() {
    if (_depth++ == 0) _db.execute('BEGIN');
  }

  void commit() {
    if (_depth == 0) return;
    if (--_depth == 0) _db.execute('COMMIT');
  }

  // ------------------------------------------------------------------ meta

  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  void setMeta(String key, String value) => _db.execute(
        'INSERT INTO meta (key, value) VALUES (?, ?) '
        'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  // --------------------------------------------------------------- records

  /// Every record of [kind] (e.g. `workers`), in the order first saved.
  List<Map<String, dynamic>> records(String kind) => [
        for (final row in _db.select(
            'SELECT json FROM records WHERE kind = ? ORDER BY rowid', [kind]))
          jsonDecode(row.columnAt(0) as String) as Map<String, dynamic>,
      ];

  /// Adds or replaces one record; a replaced one keeps its place in order.
  void putRecord(String kind, String id, Map<String, dynamic> json) =>
      _upsertRecord.execute([kind, id, jsonEncode(json)]);

  void deleteRecord(String kind, String id) =>
      _db.execute('DELETE FROM records WHERE kind = ? AND id = ?', [kind, id]);

  // --------------------------------------------------------------- punches

  static const _auto = 1, _corrected = 2, _clockSuspect = 4;

  static const _columns = 'worker_id, at, type, employee_id, worker_name, '
      'site_id, site_name, lat, lng, distance, flags, photo';

  void insertPunch(Punch p) => _insertPunch.execute([
        p.workerId,
        p.at.microsecondsSinceEpoch,
        dayKeyOf(p.at),
        p.type.name,
        p.employeeId,
        p.workerName,
        p.siteId,
        p.siteName,
        p.latitude,
        p.longitude,
        p.distanceMeters,
        (p.auto ? _auto : 0) |
            (p.corrected ? _corrected : 0) |
            (p.clockSuspect ? _clockSuspect : 0),
        p.photo,
      ]);

  /// Removes one punch. A worker never has two punches of one type in the
  /// same microsecond, so this identifies it exactly.
  void deletePunch(Punch p) => _db.execute(
        'DELETE FROM punches WHERE worker_id = ? AND at = ? AND type = ?',
        [p.workerId, p.at.microsecondsSinceEpoch, p.type.name],
      );

  void deletePunchesOf(String workerId) =>
      _db.execute('DELETE FROM punches WHERE worker_id = ?', [workerId]);

  void deleteAllPunches() => _db.execute('DELETE FROM punches');

  int get punchCount =>
      _db.select('SELECT count(*) FROM punches').first.columnAt(0) as int;

  /// Punches of days [fromDay] to [toDay] (inclusive, see [dayKeyOf]), in
  /// time order.
  List<Punch> punchesBetweenDays(int fromDay, int toDay) => _read(
        'SELECT $_columns FROM punches WHERE day BETWEEN ? AND ? '
        'ORDER BY at, id',
        [fromDay, toDay],
      );

  /// Each worker's newest punch, however old: the store needs it to know
  /// who is still clocked in, even past the days it keeps in memory.
  List<Punch> latestPunchPerWorker() => _read(
        'SELECT $_columns FROM punches p WHERE at = '
        '(SELECT max(at) FROM punches WHERE worker_id = p.worker_id) '
        'ORDER BY at, id',
        const [],
      );

  List<Punch> _read(String sql, List<Object?> args) {
    // Names and ids repeat on every punch; sharing one String each keeps a
    // month of a busy gate in memory at a fraction of the size.
    final strings = <String, String>{};
    String s(Object? v) {
      final text = v as String;
      return strings.putIfAbsent(text, () => text);
    }

    final rows = _db.select(sql, args);
    return [
      for (final r in rows)
        Punch(
          workerId: s(r.columnAt(0)),
          at: DateTime.fromMicrosecondsSinceEpoch(r.columnAt(1) as int),
          type: PunchType.values.byName(s(r.columnAt(2))),
          employeeId: s(r.columnAt(3)),
          workerName: s(r.columnAt(4)),
          siteId: s(r.columnAt(5)),
          siteName: s(r.columnAt(6)),
          latitude: (r.columnAt(7) as num).toDouble(),
          longitude: (r.columnAt(8) as num).toDouble(),
          distanceMeters: (r.columnAt(9) as num).toDouble(),
          auto: (r.columnAt(10) as int) & _auto != 0,
          corrected: (r.columnAt(10) as int) & _corrected != 0,
          clockSuspect: (r.columnAt(10) as int) & _clockSuspect != 0,
          photo: r.columnAt(11) as String?,
        ),
    ];
  }

  void close() {
    _insertPunch.close();
    _upsertRecord.close();
    _db.close();
  }
}
