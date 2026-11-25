import '../models/attendance.dart';
import '../store/attendance_store.dart';

/// What the "Ask" feature may see about one worker.
///
/// Deliberately small: no face embeddings, no photos, no GPS positions, no
/// site coordinates and no leave reasons. When a real model replaces the
/// scripted engine, this is the only data it is ever handed, so whatever is
/// not here can never reach it.
class WorkerInsight {
  const WorkerInsight({
    required this.name,
    required this.status,
    required this.workedToday,
    required this.lateToday,
    required this.overtimeToday,
    required this.onLeaveToday,
    required this.lateDaysThisWeek,
  });

  final String name;
  final WorkerStatus status;
  final Duration workedToday;
  final bool lateToday;
  final bool overtimeToday;
  final bool onLeaveToday;

  /// Days from Monday up to today on which the first check-in was late.
  final int lateDaysThisWeek;
}

class InsightData {
  const InsightData({
    required this.workers,
    required this.pendingLeave,
    required this.asOf,
  });

  /// Reads the store once, so an answer is built from one consistent
  /// moment rather than numbers that move while it renders.
  factory InsightData.from(AttendanceStore store, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final monday = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: today.weekday - 1));
    final weekDays = [
      for (var d = monday;
          !d.isAfter(today);
          d = DateTime(d.year, d.month, d.day + 1))
        d,
    ];

    return InsightData(
      asOf: today,
      pendingLeave: store.pendingLeaveCount,
      workers: [
        for (final worker in store.workers)
          () {
            final flags = store.flagsFor(worker.id, today);
            return WorkerInsight(
              name: worker.name,
              status: store.statusOf(worker.id),
              workedToday: store.workedOn(worker.id, today),
              lateToday: flags.late,
              overtimeToday: flags.overtime,
              onLeaveToday: store.leaveOn(worker.id, today) != null,
              lateDaysThisWeek: weekDays
                  .where((d) => store.flagsFor(worker.id, d).late)
                  .length,
            );
          }(),
      ],
    );
  }

  final List<WorkerInsight> workers;
  final int pendingLeave;
  final DateTime asOf;
}
