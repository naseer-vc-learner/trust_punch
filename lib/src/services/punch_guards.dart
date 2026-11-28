import '../models/attendance.dart';

/// Checks a build can add before a punch, without the shared screens
/// knowing where they come from. The offline demo adds none.
abstract final class PunchGuards {
  /// Set by the connected app: whether [worker] is checked in on another
  /// phone right now, as the server knows. Null means "can't tell" (offline,
  /// not paired), and the punch goes ahead: punching never depends on the
  /// server. The server flags it later if it did clash.
  static Future<bool?> Function(Worker worker)? checkedInElsewhere;
}
