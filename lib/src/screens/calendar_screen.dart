import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../models/requests.dart';
import '../services/punch_photo_store.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'leave_screen.dart' show leaveTypeLabel;
import 'punch_result_screen.dart' show PunchPhotoThumb;
import 'shared_widgets.dart' show formatBySite, formatHours;
import 'supervisor_pin.dart';

/// Monthly attendance: which days were worked, how long, and where.
///
/// [onlyWorker] set (a worker's own phone): only that person's days, hours
/// and leave. [canDelete] (supervisor role): adds "Delete all attendance".
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    required this.store,
    required this.lock,
    this.onlyWorker,
    this.canDelete = false,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final Worker? onlyWorker;
  final bool canDelete;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  static final _clock = DateFormat('HH:mm');
  static final _monthLabel = DateFormat('MMMM yyyy');
  static final _dayLabel = DateFormat('EEEE d MMMM');

  late DateTime _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selected = DateTime(now.year, now.month, now.day);
  }

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  /// Wipes every punch on the phone: supervisor PIN first, then an explicit
  /// confirmation, because nothing here can be recovered afterwards.
  Future<void> _clearAll() async {
    final lang = widget.store.languageCode;
    if (!await requireSupervisor(context, widget.lock, lang)) return;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(lang, T.clearAttendance)),
        content: Text(t(lang, T.clearAttendanceConfirm)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t(lang, T.cancel)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(t(lang, T.delete)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.store.clearPunches();
    // The selfies belong to those punches and go with them.
    await (await PunchPhotoStore.shared()).deleteAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t(lang, T.attendanceCleared))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.onlyWorker == null
            ? t(widget.store.languageCode, T.attendance)
            : t(widget.store.languageCode, T.myAttendance)),
        actions: [
          if (widget.canDelete)
            IconButton(
              tooltip: t(widget.store.languageCode, T.clearAttendance),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final who = widget.onlyWorker?.id;
          final totals = widget.store
              .monthTotals(_month.year, _month.month, workerId: who);
          final monthTotal = widget.store
              .monthTotal(_month.year, _month.month, workerId: who);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _MonthHeader(
                label: _monthLabel.format(_month),
                onPrevious: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
              ),
              const SizedBox(height: 8),
              _MonthSummary(
                total: monthTotal,
                daysWorked: totals.values.where((d) => d > Duration.zero).length,
                lang: widget.store.languageCode,
              ),
              const SizedBox(height: 16),
              const _WeekdayRow(),
              const SizedBox(height: 4),
              _MonthGrid(
                month: _month,
                totals: totals,
                leaveDays: widget.store
                    .leaveDaysIn(_month.year, _month.month, workerId: who),
                selected: _selected,
                onSelect: (day) => setState(() => _selected = day),
              ),
              const SizedBox(height: 24),
              Text(
                _dayLabel.format(_selected),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ..._buildDayDetail(),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildDayDetail() {
    final only = widget.onlyWorker;
    final punches = widget.store.punchesOn(_selected, workerId: only?.id);
    final onLeave = widget.store.leavesOn(_selected, workerId: only?.id);
    final people = only == null ? widget.store.workers : [only];
    if (punches.isEmpty && onLeave.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
              child: Text(t(widget.store.languageCode, T.noAttendance))),
        ),
      ];
    }

    final lang = widget.store.languageCode;
    return [
      ...onLeave.map(
        (leave) => Card(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: ListTile(
            leading: const Icon(Icons.event_busy),
            title: Text(leave.workerName),
            subtitle: Text(
              '${t(lang, T.onLeave)} · ${leaveTypeLabel(lang, leave.type)}',
            ),
          ),
        ),
      ),
      ...people.map((worker) {
        final worked = widget.store.workedOn(worker.id, _selected);
        if (worked == Duration.zero &&
            widget.store.punchesFor(worker.id, _selected).isEmpty) {
          return const SizedBox.shrink();
        }
        final flags = widget.store.flagsFor(worker.id, _selected);
        final bySite = widget.store.workedBySiteOn(worker.id, _selected);
        final travel = widget.store.travelOn(worker.id, _selected);
        final overtimeStatus =
            widget.store.overtimeStatus(worker.id, _selected);
        return Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(worker.name.characters.first)),
            title: Text(worker.name),
            isThreeLine: bySite.isNotEmpty,
            subtitle: Text([
              [
                if (worker.employeeId.isNotEmpty) worker.employeeId,
                '${t(lang, T.breakTime)} '
                    '${formatHours(widget.store.breakOn(worker.id, _selected))}',
                if (flags.late) t(lang, T.lateFlag),
                if (flags.overtime) t(lang, T.overtimeFlag),
                if (flags.short) t(lang, T.shortFlag),
                if (flags.autoCheckout) t(lang, T.autoCheckoutFlag),
                if (flags.corrected) t(lang, T.correctedFlag),
                if (flags.clockSuspect) t(lang, T.clockFlag),
                if (overtimeStatus != null)
                  '${t(lang, T.overtimeLabel)} '
                      '${formatHours(widget.store.overtimeOn(worker.id, _selected))} '
                      '(${t(lang, switch (overtimeStatus) {
                    RequestStatus.pending => T.leavePending,
                    RequestStatus.approved => T.leaveApproved,
                    RequestStatus.rejected => T.leaveRejected,
                  }).toLowerCase()})',
              ].join(' · '),
              if (bySite.isNotEmpty)
                '${t(lang, T.hoursBySite)}: ${formatBySite(bySite)}',
              if (travel > Duration.zero)
                '${t(lang, T.travel)}: ${formatHours(travel)}',
            ].join('\n')),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatHours(worked),
                    style: Theme.of(context).textTheme.titleMedium),
                Text(t(lang, T.workedToday),
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        );
      }),
      const SizedBox(height: 8),
      ...punches.map(
        (punch) => Card(
          child: ListTile(
            dense: true,
            leading: punch.photo != null
                ? PunchPhotoThumb(punch: punch)
                : Icon(switch (punch.type) {
                    PunchType.checkIn => Icons.login,
                    PunchType.checkOut => Icons.logout,
                    PunchType.breakStart => Icons.free_breakfast,
                    PunchType.breakEnd => Icons.work_outline,
                  }),
            title: Text('${punch.workerName} · ${punch.siteName}'),
            subtitle: Text([
              t(
                widget.store.languageCode,
                switch (punch.type) {
                  PunchType.checkIn => T.checkInLabel,
                  PunchType.checkOut => T.checkOutLabel,
                  PunchType.breakStart => T.takeBreak,
                  PunchType.breakEnd => T.endBreak,
                },
              ),
              // Recorded by the app when the worker moved on without
              // checking out; the time is an estimate.
              if (punch.auto)
                t(widget.store.languageCode, T.autoCheckoutFlag),
              if (punch.corrected)
                t(widget.store.languageCode, T.correctedFlag),
              if (punch.clockSuspect)
                t(widget.store.languageCode, T.clockFlag),
            ].join(' · ')),
            trailing: Text(_clock.format(punch.at)),
          ),
        ),
      ),
    ];
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.label,
    required this.onPrevious,
    required this.onNext,
  });

  final String label;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(label, style: Theme.of(context).textTheme.titleLarge),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
      ],
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({
    required this.total,
    required this.daysWorked,
    required this.lang,
  });

  final Duration total;
  final int daysWorked;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                Text(t(lang, T.totalWorked),
                    style: Theme.of(context).textTheme.labelLarge),
                Text(
                  formatHours(total),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
            Column(
              children: [
                Text(t(lang, T.daysWorked),
                    style: Theme.of(context).textTheme.labelLarge),
                Text(
                  '$daysWorked',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow();

  static const _labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _labels
          .map((l) => Expanded(
                child: Center(
                  child: Text(l, style: Theme.of(context).textTheme.labelMedium),
                ),
              ))
          .toList(),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.totals,
    required this.leaveDays,
    required this.selected,
    required this.onSelect,
  });

  final DateTime month;
  final Map<int, Duration> totals;

  /// Days on which someone is on approved leave, marked with a dot.
  final Set<int> leaveDays;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // weekday is 1=Mon..7=Sun, and the grid starts on Monday.
    final leading = DateTime(month.year, month.month, 1).weekday - 1;
    final today = DateTime.now();
    final scheme = Theme.of(context).colorScheme;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 0.85,
      ),
      itemCount: leading + daysInMonth,
      itemBuilder: (context, index) {
        if (index < leading) return const SizedBox.shrink();

        final dayNumber = index - leading + 1;
        final date = DateTime(month.year, month.month, dayNumber);
        final worked = totals[dayNumber] ?? Duration.zero;
        final hasWork = worked > Duration.zero;

        final isSelected = date.year == selected.year &&
            date.month == selected.month &&
            date.day == selected.day;
        final isToday = date.year == today.year &&
            date.month == today.month &&
            date.day == today.day;

        return InkWell(
          onTap: () => onSelect(date),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isSelected
                  ? scheme.primary
                  : hasWork
                      ? scheme.primaryContainer
                      : null,
              border: isToday && !isSelected
                  ? Border.all(color: scheme.primary, width: 2)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$dayNumber',
                  style: TextStyle(
                    color: isSelected ? scheme.onPrimary : null,
                    fontWeight: hasWork ? FontWeight.bold : null,
                  ),
                ),
                if (hasWork)
                  Text(
                    '${worked.inHours}h',
                    style: TextStyle(
                      fontSize: 10,
                      color: isSelected
                          ? scheme.onPrimary
                          : scheme.onPrimaryContainer,
                    ),
                  ),
                if (leaveDays.contains(dayNumber))
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: isSelected ? scheme.onPrimary : scheme.tertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
