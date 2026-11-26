import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../models/project.dart';
import '../services/face_recognizer.dart';
import '../services/location_service.dart';
import '../services/speech_service.dart';
import '../store/attendance_store.dart';
import 'shared_widgets.dart' show showSnack;
import 'workers_screen.dart' show registerWorkerFlow;

/// Supervisor setup, in the order the work happens: create a project, give
/// it jobs (activities) and roles, add its locations with their shifts, and
/// put workers on it. English-only, like the other supervisor screens.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({
    super.key,
    required this.store,
    required this.recognizer,
    required this.speech,
  });

  final AttendanceStore store;
  final FaceRecognizer recognizer;
  final SpeechService speech;

  String get _lang => store.languageCode;

  Future<void> _create(BuildContext context) async {
    final name = await askText(
      context,
      title: t(_lang, T.newProject),
      label: t(_lang, T.projectName),
      saveLabel: t(_lang, T.save),
      cancelLabel: t(_lang, T.cancel),
    );
    if (name == null || !context.mounted) return;
    final project = await store.addProject(name);
    if (context.mounted) _open(context, project.id);
  }

  void _open(BuildContext context, String projectId) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ProjectScreen(
          store: store,
          recognizer: recognizer,
          speech: speech,
          projectId: projectId,
        ),
      ));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(_lang, T.projects))),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final projects = store.projects;
          return Column(
            children: [
              Expanded(
                child: projects.isEmpty
                    ? Center(child: Text(t(_lang, T.noProjectsYet)))
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          for (final p in projects)
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.apartment),
                                title: Text(p.name),
                                subtitle: Text(
                                  '${store.sitesOf(p.id).length} locations · '
                                  '${store.workersOf(p.id).length} workers · '
                                  '${p.jobs.length} jobs',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _open(context, p.id),
                              ),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_business),
                  label: Text(t(_lang, T.newProject)),
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
}

/// One project: jobs, roles, locations with shifts, and its workers.
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({
    super.key,
    required this.store,
    required this.recognizer,
    required this.speech,
    required this.projectId,
  });

  final AttendanceStore store;
  final FaceRecognizer recognizer;
  final SpeechService speech;
  final String projectId;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  bool _locating = false;

  AttendanceStore get _store => widget.store;
  String get _lang => _store.languageCode;
  Project? get _project => _store.projectById(widget.projectId);

  // ------------------------------------------------------------ jobs & roles

  Future<void> _addListItem({required bool job}) async {
    final project = _project;
    if (project == null) return;
    final value = await askText(
      context,
      title: t(_lang, job ? T.addJob : T.addRole),
      label: t(_lang, job ? T.job : T.role),
      saveLabel: t(_lang, T.save),
      cancelLabel: t(_lang, T.cancel),
    );
    if (value == null) return;
    final list = job ? project.jobs : project.roles;
    if (list.contains(value)) return;
    await _store.updateProject(job
        ? project.copyWith(jobs: [...project.jobs, value])
        : project.copyWith(roles: [...project.roles, value]));
  }

  Future<void> _removeListItem(String value, {required bool job}) async {
    final project = _project;
    if (project == null) return;
    await _store.updateProject(job
        ? project.copyWith(jobs: project.jobs.where((j) => j != value).toList())
        : project.copyWith(
            roles: project.roles.where((r) => r != value).toList()));
  }

  // --------------------------------------------------------------- locations

  /// Saves where the supervisor is standing as a location of this project,
  /// with its shift. Refuses a vague GPS fix, as check-in does.
  Future<void> _addLocation() async {
    final name = await askText(
      context,
      title: t(_lang, T.nameThisSite),
      label: t(_lang, T.name),
      saveLabel: t(_lang, T.save),
      cancelLabel: t(_lang, T.cancel),
    );
    if (name == null || !mounted) return;
    final shift = await askShift(context, lang: _lang);
    if (shift == null || !mounted) return;

    setState(() => _locating = true);
    try {
      final fix = await LocationService().currentFix();
      if (!mounted) return;
      if (!fix.isPrecise) {
        showSnack(context,
            '${t(_lang, T.weakLocation)} (±${fix.accuracyMeters.round()} m)');
        return;
      }
      await _store.addSite(Site(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        latitude: fix.latitude,
        longitude: fix.longitude,
        projectId: widget.projectId,
        shiftStartMinutes: shift.$1,
        shiftEndMinutes: shift.$2,
      ));
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Adds a location from typed coordinates, for a site the supervisor is
  /// not standing at. Same name and shift steps as adding by GPS.
  Future<void> _addLocationByCoordinates() async {
    final name = await askText(
      context,
      title: t(_lang, T.nameThisSite),
      label: t(_lang, T.name),
      saveLabel: t(_lang, T.save),
      cancelLabel: t(_lang, T.cancel),
    );
    if (name == null || !mounted) return;
    final point = await askCoordinates(context, lang: _lang);
    if (point == null || !mounted) return;
    final shift = await askShift(context, lang: _lang);
    if (shift == null || !mounted) return;

    await _store.addSite(Site(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      latitude: point.$1,
      longitude: point.$2,
      projectId: widget.projectId,
      shiftStartMinutes: shift.$1,
      shiftEndMinutes: shift.$2,
    ));
  }

  Future<void> _editShift(Site site) async {
    final shift = await askShift(
      context,
      lang: _lang,
      start: site.shiftStartMinutes,
      end: site.shiftEndMinutes,
    );
    if (shift == null) return;
    await _store.setShift(site.id, shift.$1, shift.$2);
  }

  // ----------------------------------------------------------------- workers

  Future<void> _registerWorker() => registerWorkerFlow(
        context,
        store: _store,
        recognizer: widget.recognizer,
        speech: widget.speech,
        projectId: widget.projectId,
      );

  /// Moves a worker from another project onto this one.
  Future<void> _addExisting() async {
    final others =
        _store.workers.where((w) => w.projectId != widget.projectId).toList();
    if (others.isEmpty) {
      showSnack(context, t(_lang, T.noWorkers));
      return;
    }
    final picked = await showDialog<Worker>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t(_lang, T.assignWorker)),
        children: [
          for (final w in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, w),
              child: Text(
                '${w.name} · ${_store.projectById(w.projectId)?.name ?? ''}',
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _editAssignment(picked);
  }

  Future<void> _editAssignment(Worker worker) async {
    final project = _project;
    if (project == null) return;
    final choice = await askAssignment(
      context,
      lang: _lang,
      project: project,
      role: worker.projectId == project.id ? worker.role : '',
      job: worker.projectId == project.id ? worker.job : '',
    );
    if (choice == null) return;
    await _store.assignWorker(
      worker.id,
      projectId: project.id,
      role: choice.$1,
      job: choice.$2,
    );
  }

  Future<void> _deleteProject() async {
    final removed = await _store.removeProject(widget.projectId);
    if (!mounted) return;
    if (removed) {
      Navigator.of(context).pop();
    } else {
      showSnack(context, t(_lang, T.projectNotEmpty));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final project = _project;
        if (project == null) return const Scaffold();
        final sites = _store.sitesOf(project.id);
        final workers = _store.workersOf(project.id);
        final text = Theme.of(context).textTheme;

        return Scaffold(
          appBar: AppBar(
            title: Text(project.name),
            actions: [
              IconButton(
                tooltip: t(_lang, T.delete),
                icon: const Icon(Icons.delete_outline),
                onPressed: _deleteProject,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 1. Jobs and roles: the lists workers are given from.
              _Section(title: t(_lang, T.jobs)),
              _ChipList(
                items: project.jobs,
                empty: t(_lang, T.noneYet),
                onRemove: (j) => _removeListItem(j, job: true),
                addLabel: t(_lang, T.addJob),
                onAdd: () => _addListItem(job: true),
              ),
              _Section(title: t(_lang, T.roles)),
              _ChipList(
                items: project.roles,
                empty: t(_lang, T.noneYet),
                onRemove: (r) => _removeListItem(r, job: false),
                addLabel: t(_lang, T.addRole),
                onAdd: () => _addListItem(job: false),
              ),

              // 2. Locations, each with its own shift.
              _Section(title: t(_lang, T.locations)),
              if (sites.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(t(_lang, T.noLocationsYet), style: text.bodySmall),
                ),
              for (final site in sites)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(site.name),
                    subtitle: Text(
                      '${t(_lang, T.shift)} '
                      '${formatShiftTime(site.shiftStartMinutes)}–'
                      '${formatShiftTime(site.shiftEndMinutes)}\n'
                      '${site.latitude.toStringAsFixed(5)}, '
                      '${site.longitude.toStringAsFixed(5)}',
                    ),
                    isThreeLine: true,
                    onTap: () => _editShift(site),
                    trailing: IconButton(
                      tooltip: t(_lang, T.delete),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _store.removeSite(site.id),
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _locating ? null : _addLocation,
                    icon: _locating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_location_alt),
                    label: Text(t(_lang, T.addCurrentLocation)),
                  ),
                  OutlinedButton.icon(
                    onPressed: _locating ? null : _addLocationByCoordinates,
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: Text(t(_lang, T.enterCoordinates)),
                  ),
                ],
              ),

              // 3. Workers, each with a role and a job.
              _Section(title: t(_lang, T.workers)),
              if (workers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(t(_lang, T.noWorkers), style: text.bodySmall),
                ),
              for (final w in workers)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text(w.name.characters.first)),
                    title: Text(w.name),
                    subtitle: Text([
                      if (w.role.isNotEmpty) w.role,
                      if (w.job.isNotEmpty) w.job,
                    ].join(' · ')),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _editAssignment(w),
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _registerWorker,
                    icon: const Icon(Icons.person_add),
                    label: Text(t(_lang, T.registerWorker)),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addExisting,
                    icon: const Icon(Icons.group_add_outlined),
                    label: Text(t(_lang, T.assignWorker)),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _ChipList extends StatelessWidget {
  const _ChipList({
    required this.items,
    required this.empty,
    required this.onRemove,
    required this.addLabel,
    required this.onAdd,
  });

  final List<String> items;
  final String empty;
  final ValueChanged<String> onRemove;
  final String addLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (items.isEmpty)
            Text(empty, style: Theme.of(context).textTheme.bodySmall),
          for (final item in items)
            InputChip(label: Text(item), onDeleted: () => onRemove(item)),
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
            onPressed: onAdd,
          ),
        ],
      );
}

// ------------------------------------------------------------------ dialogs

/// Asks for one line of text; null when cancelled or left empty.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  required String saveLabel,
  required String cancelLabel,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(
        title: title,
        label: label,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
      ),
    );

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.saveLabel,
    required this.cancelLabel,
  });

  final String title;
  final String label;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: widget.label),
          onSubmitted: (_) => _save(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.cancelLabel),
          ),
          FilledButton(onPressed: _save, child: Text(widget.saveLabel)),
        ],
      );
}

/// Asks for a shift as (start, end) minutes after midnight; null when
/// cancelled. Refuses a shift that ends before it starts.
Future<(int, int)?> askShift(
  BuildContext context, {
  required String lang,
  int start = Site.defaultShiftStart,
  int end = Site.defaultShiftEnd,
}) =>
    showDialog<(int, int)>(
      context: context,
      builder: (_) => _ShiftDialog(lang: lang, start: start, end: end),
    );

class _ShiftDialog extends StatefulWidget {
  const _ShiftDialog({
    required this.lang,
    required this.start,
    required this.end,
  });

  final String lang;
  final int start;
  final int end;

  @override
  State<_ShiftDialog> createState() => _ShiftDialogState();
}

class _ShiftDialogState extends State<_ShiftDialog> {
  late int _start = widget.start;
  late int _end = widget.end;
  String? _error;

  Future<void> _pick({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null) return;
    setState(() {
      final minutes = picked.hour * 60 + picked.minute;
      if (start) {
        _start = minutes;
      } else {
        _end = minutes;
      }
      _error = null;
    });
  }

  void _save() {
    if (_end <= _start) {
      setState(() => _error = t(widget.lang, T.shiftEndBeforeStart));
      return;
    }
    Navigator.pop(context, (_start, _end));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(t(widget.lang, T.shift)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pick(start: true),
                    child: Text(formatShiftTime(_start)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('–'),
                ),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pick(start: false),
                    child: Text(formatShiftTime(_end)),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t(widget.lang, T.cancel)),
          ),
          FilledButton(onPressed: _save, child: Text(t(widget.lang, T.save))),
        ],
      );
}

/// Asks for (latitude, longitude) in decimal degrees; null when cancelled.
/// A pair pasted into the latitude field ("25.2048, 55.2708") is split
/// across both fields.
Future<(double, double)?> askCoordinates(
  BuildContext context, {
  required String lang,
}) =>
    showDialog<(double, double)>(
      context: context,
      builder: (_) => _CoordinatesDialog(lang: lang),
    );

class _CoordinatesDialog extends StatefulWidget {
  const _CoordinatesDialog({required this.lang});

  final String lang;

  @override
  State<_CoordinatesDialog> createState() => _CoordinatesDialogState();
}

class _CoordinatesDialogState extends State<_CoordinatesDialog> {
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  void _onLatitudeChanged(String text) {
    final pair = splitLatLngPair(text);
    if (pair == null) return;
    _lat.text = pair.$1;
    _lng.text = pair.$2;
  }

  void _save() {
    final point = parseLatLng(_lat.text, _lng.text);
    if (point == null) {
      setState(() => _error = t(widget.lang, T.coordinatesInvalid));
      return;
    }
    Navigator.pop(context, point);
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    const keyboard =
        TextInputType.numberWithOptions(decimal: true, signed: true);
    return AlertDialog(
      title: Text(t(lang, T.enterCoordinates)),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t(lang, T.coordinatesHelp),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _lat,
            autofocus: true,
            // Not the numeric keyboard: it could not take a pasted pair.
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: t(lang, T.latitude),
              hintText: '25.2048',
            ),
            onChanged: _onLatitudeChanged,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _lng,
            keyboardType: keyboard,
            decoration: InputDecoration(
              labelText: t(lang, T.longitude),
              hintText: '55.2708',
              errorText: _error,
              errorMaxLines: 2,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(lang, T.cancel)),
        ),
        FilledButton(onPressed: _save, child: Text(t(lang, T.save))),
      ],
    );
  }
}

/// Asks for a worker's (role, job) on [project]; null when cancelled.
/// Empty strings mean "not set": a project may not have roles or jobs yet.
Future<(String, String)?> askAssignment(
  BuildContext context, {
  required String lang,
  required Project project,
  String role = '',
  String job = '',
}) =>
    showDialog<(String, String)>(
      context: context,
      builder: (_) => _AssignmentDialog(
        lang: lang,
        project: project,
        role: role,
        job: job,
      ),
    );

class _AssignmentDialog extends StatefulWidget {
  const _AssignmentDialog({
    required this.lang,
    required this.project,
    required this.role,
    required this.job,
  });

  final String lang;
  final Project project;
  final String role;
  final String job;

  @override
  State<_AssignmentDialog> createState() => _AssignmentDialogState();
}

class _AssignmentDialogState extends State<_AssignmentDialog> {
  late String? _role =
      widget.project.roles.contains(widget.role) ? widget.role : null;
  late String? _job =
      widget.project.jobs.contains(widget.job) ? widget.job : null;

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    return AlertDialog(
      title: Text(widget.project.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: InputDecoration(labelText: t(lang, T.role)),
            hint: Text(widget.project.roles.isEmpty ? t(lang, T.noneYet) : ''),
            items: [
              for (final r in widget.project.roles)
                DropdownMenuItem(value: r, child: Text(r)),
            ],
            onChanged: (r) => setState(() => _role = r),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _job,
            decoration: InputDecoration(labelText: t(lang, T.job)),
            hint: Text(widget.project.jobs.isEmpty ? t(lang, T.noneYet) : ''),
            items: [
              for (final j in widget.project.jobs)
                DropdownMenuItem(value: j, child: Text(j)),
            ],
            onChanged: (j) => setState(() => _job = j),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(lang, T.cancel)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_role ?? '', _job ?? '')),
          child: Text(t(lang, T.save)),
        ),
      ],
    );
  }
}
