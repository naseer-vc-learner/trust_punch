import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../models/leave.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'supervisor_pin.dart';

String leaveTypeLabel(String lang, LeaveType type) => t(lang, switch (type) {
      LeaveType.annual => T.annualLeave,
      LeaveType.sick => T.sickLeave,
      LeaveType.unpaid => T.unpaidLeave,
    });

final _day = DateFormat('d MMM yyyy');

String leaveDatesLabel(LeaveRequest leave) => leave.from == leave.to
    ? _day.format(leave.from)
    : '${_day.format(leave.from)} – ${_day.format(leave.to)}';

/// Asks for leave and files it as pending. Used by the Leave screen and,
/// without any list, by the gate kiosk.
///
/// [fixedWorker] set: the request is for that person only (a worker's own
/// phone). Null: the person picks who it is for.
Future<void> requestLeaveFlow(
  BuildContext context,
  AttendanceStore store, {
  Worker? fixedWorker,
}) async {
  final lang = store.languageCode;
  void snack(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  if (store.workers.isEmpty) {
    snack(t(lang, T.noWorkers));
    return;
  }
  final draft = await showDialog<_LeaveDraft>(
    context: context,
    builder: (_) => _RequestLeaveDialog(store: store, fixedWorker: fixedWorker),
  );
  if (draft == null || !context.mounted) return;

  try {
    await store.requestLeave(
      worker: draft.worker,
      type: draft.type,
      from: draft.dates.start,
      to: draft.dates.end,
      reason: draft.reason,
    );
    if (context.mounted) snack(t(lang, T.leaveRequested));
  } on StateError {
    if (context.mounted) snack(t(lang, T.leaveOverlap));
  }
}

/// Leave requests: anyone can ask, only a supervisor decides.
///
/// [onlyWorker] set (a worker's own phone): shows and files only that
/// person's leave. [canDecide] (supervisor role): adds approve, reject and
/// delete, each still checked against the supervisor PIN — which passes
/// straight through inside the supervisor's session.
class LeaveScreen extends StatefulWidget {
  const LeaveScreen({
    super.key,
    required this.store,
    required this.lock,
    this.onlyWorker,
    this.canDecide = false,
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final Worker? onlyWorker;
  final bool canDecide;

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  bool _unlocked = false;

  String get _lang => widget.store.languageCode;

  Future<bool> _ensureSupervisor() async {
    if (_unlocked) return true;
    final ok = await requireSupervisor(context, widget.lock, _lang);
    if (ok) _unlocked = true;
    return ok;
  }

  Future<void> _request() => requestLeaveFlow(
        context,
        widget.store,
        fixedWorker: widget.onlyWorker,
      );

  Future<void> _decide(LeaveRequest leave, {required bool approve}) async {
    if (!await _ensureSupervisor()) return;
    await widget.store.decideLeave(leave.id, approve: approve);
  }

  Future<void> _delete(LeaveRequest leave) async {
    if (!await _ensureSupervisor()) return;
    await widget.store.removeLeave(leave.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(_lang, T.leave))),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final only = widget.onlyWorker;
          final leaves = only == null
              ? widget.store.leaves
              : widget.store.leaves.where((l) => l.workerId == only.id).toList();
          // Pending first: that is the queue someone has to act on.
          final sections = [
            for (final status in LeaveStatus.values)
              (status, leaves.where((l) => l.status == status).toList()),
          ].where((s) => s.$2.isNotEmpty);

          return Column(
            children: [
              Expanded(
                child: leaves.isEmpty
                    ? Center(child: Text(t(_lang, T.noLeaveYet)))
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          for (final (status, items) in sections) ...[
                            _SectionHeader(
                              '${_statusLabel(status)} (${items.length})',
                            ),
                            for (final leave in items)
                              _LeaveCard(
                                leave: leave,
                                lang: _lang,
                                canDecide: widget.canDecide,
                                onApprove: () => _decide(leave, approve: true),
                                onReject: () => _decide(leave, approve: false),
                                onDelete: () => _delete(leave),
                              ),
                          ],
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _request,
                  icon: const Icon(Icons.event_busy),
                  label: Text(t(_lang, T.requestLeave)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _statusLabel(LeaveStatus status) => t(_lang, switch (status) {
        LeaveStatus.pending => T.leavePending,
        LeaveStatus.approved => T.leaveApproved,
        LeaveStatus.rejected => T.leaveRejected,
      });
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _LeaveCard extends StatelessWidget {
  const _LeaveCard({
    required this.leave,
    required this.lang,
    required this.canDecide,
    required this.onApprove,
    required this.onReject,
    required this.onDelete,
  });

  final LeaveRequest leave;
  final String lang;
  final bool canDecide;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final pending = leave.status == LeaveStatus.pending;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${leave.workerName} · ${leaveTypeLabel(lang, leave.type)}',
                    style: text.titleMedium,
                  ),
                ),
                if (canDecide && !pending)
                  IconButton(
                    tooltip: t(lang, T.delete),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onDelete,
                  ),
              ],
            ),
            Text(
              '${leaveDatesLabel(leave)} · '
              '${t(lang, T.leaveDays).replaceAll('{n}', '${leave.days}')}',
            ),
            if (leave.reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(leave.reason, style: text.bodySmall),
            ],
            if (canDecide && pending) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onReject,
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    child: Text(t(lang, T.reject)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onApprove,
                    child: Text(t(lang, T.approve)),
                  ),
                ],
              ),
            ] else
              const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _LeaveDraft {
  const _LeaveDraft(this.worker, this.type, this.dates, this.reason);

  final Worker worker;
  final LeaveType type;
  final DateTimeRange dates;
  final String reason;
}

class _RequestLeaveDialog extends StatefulWidget {
  const _RequestLeaveDialog({required this.store, this.fixedWorker});

  final AttendanceStore store;
  final Worker? fixedWorker;

  @override
  State<_RequestLeaveDialog> createState() => _RequestLeaveDialogState();
}

class _RequestLeaveDialogState extends State<_RequestLeaveDialog> {
  final _reason = TextEditingController();
  Worker? _worker;
  LeaveType _type = LeaveType.annual;
  DateTimeRange? _dates;
  String? _error;

  String get _lang => widget.store.languageCode;

  @override
  void initState() {
    super.initState();
    final workers = widget.store.workers;
    _worker = widget.fixedWorker ?? (workers.length == 1 ? workers.first : null);
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final today = dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      // Sick leave is often recorded after the fact, so the past is allowed.
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: _dates,
    );
    if (picked != null) setState(() => _dates = picked);
  }

  void _submit() {
    final worker = _worker;
    final dates = _dates;
    if (worker == null) {
      setState(() => _error = t(_lang, T.chooseWorker));
      return;
    }
    if (dates == null) {
      setState(() => _error = t(_lang, T.pickDates));
      return;
    }
    if (widget.store.hasOverlappingLeave(worker.id, dates.start, dates.end)) {
      setState(() => _error = t(_lang, T.leaveOverlap));
      return;
    }
    Navigator.pop(context, _LeaveDraft(worker, _type, dates, _reason.text));
  }

  @override
  Widget build(BuildContext context) {
    final workers = widget.store.workers;
    final dates = _dates;

    return AlertDialog(
      title: Text(t(_lang, T.requestLeave)),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A worker's own phone files leave for its owner only.
          if (widget.fixedWorker != null)
            InputDecorator(
              decoration: InputDecoration(labelText: t(_lang, T.worker)),
              child: Text(widget.fixedWorker!.name),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _worker?.id,
              decoration: InputDecoration(labelText: t(_lang, T.worker)),
              items: workers
                  .map((w) =>
                      DropdownMenuItem(value: w.id, child: Text(w.name)))
                  .toList(),
              onChanged: (id) => setState(() {
                _worker = workers.firstWhere((w) => w.id == id);
                _error = null;
              }),
            ),
          const SizedBox(height: 16),
          Text(t(_lang, T.leaveType),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final type in LeaveType.values)
                ChoiceChip(
                  label: Text(leaveTypeLabel(_lang, type)),
                  selected: _type == type,
                  onSelected: (_) => setState(() => _type = type),
                ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickDates,
            icon: const Icon(Icons.date_range),
            label: Text(
              dates == null
                  ? t(_lang, T.pickDates)
                  : dates.start == dates.end
                      ? _day.format(dates.start)
                      : '${_day.format(dates.start)} – ${_day.format(dates.end)}',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLength: 200,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: t(_lang, T.reason)),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(_lang, T.cancel)),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(t(_lang, T.submit)),
        ),
      ],
    );
  }
}
