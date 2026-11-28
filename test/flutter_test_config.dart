import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trust_punch/src/store/attendance_database.dart';

/// Runs before every test file: each test gets its own empty in-memory
/// database (tests have no app folder). Within one test, reloading the
/// store reads the same database, as a restart would.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => AttendanceDatabase.debugUse(AttendanceDatabase.inMemory()));
  tearDown(() => AttendanceDatabase.debugUse(null));
  await testMain();
}
