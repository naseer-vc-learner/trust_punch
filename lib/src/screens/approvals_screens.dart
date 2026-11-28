import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../models/requests.dart';
import '../store/attendance_store.dart';
import 'shared_widgets.dart' show formatHours, showSnack;

final _date = DateFormat('EEE d MMM');
final _dateTime = DateFormat('EEE d MMM HH:mm');
final _time = DateFormat('HH:mm');

String _statusLabel(String lang, RequestStatus status) =>
    t(lang, switch (status) {
      RequestStatus.pending => T.leavePending,
      RequestStatus.approved => T.leaveApproved,
      RequestStatus.rejected => T.leaveRejected,
    });

String _typeLabel(String lang, PunchType type) =>
    t(lang, type == PunchType.checkIn ? T.checkInLabel : T.checkOutLabel);

/// Overtime waiting for a decision, then the decisions already made.
/// Reached only from the supervisor home, inside the PIN session.
class OvertimeScreen extends StatelessWidget {
  const OvertimeScreen({super.key, required this.store});

  final AttendanceStore store;

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(t(lang, T.overtimeApprovals))),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final pending = store.pendingOvertime;
          final decided = store.overtimeDecisions;
          final names = {for (final w in store.workers) w.id: w.name};
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (pending.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(t(lang, T.noOvertime))),
                ),
              for (final (worker, day) in pending)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${worker.name} · ${_date.format(day)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${t(lang, T.workedToday)} '
                          '${formatHours(store.workedOn(worker.id, day))} · '
                          '${t(lang, T.overtimeLabel)} '
                          '${formatHours(store.overtimeOn(worker.id, day))}',
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => store.decideOvertime(
                                worker.id,
                                day,
                                approve: false,
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                              child: Text(t(lang, T.reject)),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () => store.decideOvertime(
                                worker.id,
                                day,
                                approve: true,
                              ),
                              child: Text(t(lang, T.approve)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (decided.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final d in decided)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      d.approved ? Icons.check_circle : Icons.cancel,
                      color: d.approved
                          ? const Color(0xFF2E7D32)
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      '${names[d.workerId] ?? '?'} · '
                      '${_date.format(d.date)}',
                    ),
                    subtitle: Text(
                      d.approved
                          ? '${t(lang, T.leaveApproved)}: '
                                '${formatHours(Duration(minutes: d.minutes))}'
                          : t(lang, T.leaveRejected),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Correction requests: pending first, with approve and reject; then the
/// decided ones with what they replaced.
class CorrectionsScreen extends StatelessWidget {
  const CorrectionsScreen({super.key, required this.store});

  final AttendanceStore store;

  Future<void> _decide(
    BuildContext context,
    CorrectionRequest request, {
    required bool approve,
  }) async {
    try {
      await store.decideCorrection(request.id, approve: approve);
    } on StateError {
      if (context.mounted) {
        showSnack(context, t(store.languageCode, T.correctionNotFit));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = store.languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(t(lang, T.punchCorrections))),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final all = store.corrections;
          final pending = all
              .where((c) => c.status == RequestStatus.pending)
              .toList();
          final decided = all
              .where((c) => c.status != RequestStatus.pending)
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(t(lang, T.noCorrections))),
                ),
              for (final c in [...pending, ...decided])
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c.workerName} · ${_typeLabel(lang, c.type)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text('${_dateTime.format(c.at)} · ${c.siteName}'),
                        const SizedBox(height: 4),
                        Text(
                          '"${c.reason}"',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        if (c.status == RequestStatus.pending)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    _decide(context, c, approve: false),
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                                child: Text(t(lang, T.reject)),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () =>
                                    _decide(context, c, approve: true),
                                child: Text(t(lang, T.approve)),
                              ),
                            ],
                          )
                        else
                          Text(
                            [
                              _statusLabel(lang, c.status),
                              if (c.replacedAt != null)
                                '${t(lang, T.replacedLabel)} '
                                    '${_time.format(c.replacedAt!)}'
                                    '${c.replacedAuto ? ' (${t(lang, T.autoCheckoutFlag).toLowerCase()})' : ''}',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A worker (or a gate phone on their behalf) reports a missed check-in or
/// check-out. It waits for a supervisor; nothing changes until then.
///
/// [fixedWorker] set: a personal phone, the request is for its owner.
Future<void> requestCorrectionFlow(
  BuildContext context,
  AttendanceStore store, {
  Worker? fixedWorker,
}) async {
  final lang = store.languageCode;
  if (store.workers.isEmpty) {
    showSnack(context, t(lang, T.noWorkers));
    return;
  }
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => _CorrectionDialog(store: store, fixedWorker: fixedWorker),
  );
  if (sent == true && context.mounted) {
    showSnack(context, t(lang, T.correctionSent));
  }
}

class _CorrectionDialog extends StatefulWidget {
  const _CorrectionDialog({required this.store, this.fixedWorker});

  final AttendanceStore store;
  final Worker? fixedWorker;

  @override
  State<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<_CorrectionDialog> {
  final _reason = TextEditingController();
  late Worker? _worker =
      widget.fixedWorker ??
      (widget.store.workers.length == 1 ? widget.store.workers.first : null);
  PunchType _type = PunchType.checkOut;
  DateTime _day = DateTime.now();
  TimeOfDay _time = TimeOfDay.now();
  Site? _site;
  String? _error;

  String get _lang => widget.store.languageCode;

  List<Site> get _sites {
    final worker = _worker;
    // The locations of every project they are on.
    return worker == null
        ? const []
        : [
            for (final s in widget.store.sites)
              if (widget.store.canPunchAt(worker, s)) s,
          ];
  }

  @override
  void initState() {
    super.initState();
    final sites = _sites;
    _site = sites.length == 1 ? sites.first : null;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  DateTime get _at =>
      DateTime(_day.year, _day.month, _day.day, _time.hour, _time.minute);

  Future<void> _pickDay() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: today.subtract(const Duration(days: 14)),
      lastDate: today,
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    final worker = _worker;
    final site = _site;
    if (worker == null) {
      setState(() => _error = t(_lang, T.chooseWorker));
      return;
    }
    if (site == null) {
      setState(() => _error = t(_lang, T.locationLabel));
      return;
    }
    try {
      await widget.store.requestCorrection(
        worker: worker,
        site: site,
        type: _type,
        at: _at,
        reason: _reason.text,
      );
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = _lang;
    final workers = widget.store.workers;
    return AlertDialog(
      title: Text(t(lang, T.fixPunch)),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.fixedWorker != null)
            InputDecorator(
              decoration: InputDecoration(labelText: t(lang, T.worker)),
              child: Text(widget.fixedWorker!.name),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _worker?.id,
              decoration: InputDecoration(labelText: t(lang, T.worker)),
              items: [
                for (final w in workers)
                  DropdownMenuItem(value: w.id, child: Text(w.name)),
              ],
              onChanged: (id) => setState(() {
                _worker = workers.firstWhere((w) => w.id == id);
                final sites = _sites;
                _site = sites.length == 1 ? sites.first : null;
                _error = null;
              }),
            ),
          const SizedBox(height: 16),
          Text(
            t(lang, T.missedWhat),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final type in [PunchType.checkIn, PunchType.checkOut])
                ChoiceChip(
                  label: Text(_typeLabel(lang, type)),
                  selected: _type == type,
                  onSelected: (_) => setState(() => _type = type),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            t(lang, T.whenLabel),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDay,
                  icon: const Icon(Icons.event),
                  label: Text(_date.format(_day)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(_time.format(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('site-${_worker?.id}'),
            initialValue: _site?.id,
            decoration: InputDecoration(labelText: t(lang, T.locationLabel)),
            items: [
              for (final s in _sites)
                DropdownMenuItem(
                  value: s.id,
                  // Two projects can share a place (and its name).
                  child: Text(
                    '${s.name} · '
                    '${widget.store.projectById(s.projectId)?.name ?? ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) =>
                setState(() => _site = _sites.firstWhere((s) => s.id == id)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLength: 200,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: t(lang, T.reasonRequired)),
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
          onPressed: () => Navigator.pop(context, false),
          child: Text(t(lang, T.cancel)),
        ),
        FilledButton(onPressed: _submit, child: Text(t(lang, T.submit))),
      ],
    );
  }
}
