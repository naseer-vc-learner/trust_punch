import 'package:a2ui_core/a2ui_core.dart';

import '../models/attendance.dart';
import 'insight_data.dart';
import 'trustpunch_catalog.dart';

/// Screens an answer may offer to open. The Ask screen refuses any other
/// value, whoever wrote the answer.
const openableScreens = {'leave', 'attendance'};

/// Turns a supervisor's question into A2UI messages describing the answer.
///
/// Today's only implementation is [ScriptedAskEngine], which needs no
/// network. A model-backed engine (through your own server, never with an
/// API key in the app) can replace it later without touching the screen:
/// it gets the same [InsightData] and returns the same kind of messages.
abstract interface class AskEngine {
  /// Messages that create [surfaceId] and fill it with the answer.
  Future<List<Map<String, Object?>>> answer(
    String question,
    InsightData data, {
    required String surfaceId,
  });
}

enum AskTopic { onSite, late, overtime, leave, unknown }

/// Picks what a question is about from its words. Simple on purpose: the
/// demo answers four kinds of question and says so for anything else.
AskTopic topicOf(String question) {
  final q = question.toLowerCase();
  if (q.contains('late')) return AskTopic.late;
  if (q.contains('overtime') || q.contains('hours')) return AskTopic.overtime;
  if (q.contains('leave') || q.contains('approv') || q.contains('waiting')) {
    return AskTopic.leave;
  }
  if (q.contains('site') ||
      q.contains('who is') ||
      q.contains('working') ||
      q.contains('now')) {
    return AskTopic.onSite;
  }
  return AskTopic.unknown;
}

/// Answers from this phone's own data, with no model and no network, so the
/// client demo works anywhere and costs nothing.
class ScriptedAskEngine implements AskEngine {
  const ScriptedAskEngine();

  @override
  Future<List<Map<String, Object?>>> answer(
    String question,
    InsightData data, {
    required String surfaceId,
  }) async {
    final ui = _Ui();
    final root = switch (topicOf(question)) {
      AskTopic.onSite => _onSite(ui, data),
      AskTopic.late => _late(ui, data),
      AskTopic.overtime => _overtime(ui, data),
      AskTopic.leave => _leave(ui, data),
      AskTopic.unknown => _unknown(ui),
    };
    return [
      {
        'version': '1.0',
        'createSurface': {
          'surfaceId': surfaceId,
          'catalogId': BasicCatalog.v1_0Id,
        },
      },
      {
        'version': '1.0',
        'updateComponents': {
          'surfaceId': surfaceId,
          'components': [
            ...ui.components,
            {'id': 'root', 'component': 'Column', 'children': root},
          ],
        },
      },
    ];
  }

  List<String> _onSite(_Ui ui, InsightData data) {
    var working = 0, onBreak = 0, onLeave = 0, notIn = 0;
    for (final w in data.workers) {
      switch (w.status) {
        case WorkerStatus.working:
          working++;
        case WorkerStatus.onBreak:
          onBreak++;
        case WorkerStatus.off:
          w.onLeaveToday ? onLeave++ : notIn++;
      }
    }
    final absent = [
      for (final w in data.workers)
        if (w.status == WorkerStatus.off && !w.onLeaveToday) w,
    ];
    return [
      ui.text('## On site now'),
      ui.row([
        ui.stat('Working', working, 'good'),
        ui.stat('On break', onBreak, 'warning'),
        ui.stat('On leave', onLeave, 'neutral'),
        ui.stat('Not in', notIn, notIn > 0 ? 'alert' : 'neutral'),
      ]),
      if (absent.isNotEmpty) ...[
        ui.text('Not in yet and not on leave:', caption: true),
        for (final w in absent) ui.worker(w.name, 'No check-in today', 'alert'),
      ],
    ];
  }

  List<String> _late(_Ui ui, InsightData data) {
    final late = data.workers.where((w) => w.lateDaysThisWeek > 0).toList()
      ..sort((a, b) => b.lateDaysThisWeek.compareTo(a.lateDaysThisWeek));
    if (late.isEmpty) {
      return [
        ui.text('## Late this week'),
        ui.text('Nobody has been late this week.'),
      ];
    }
    return [
      ui.text('## Late this week'),
      ui.text(
        '${late.length} of ${data.workers.length} workers were late at least '
        'once since Monday (after 09:10).',
        caption: true,
      ),
      for (final w in late)
        ui.worker(
          w.name,
          '${w.lateDaysThisWeek} late ${w.lateDaysThisWeek == 1 ? 'day' : 'days'}'
          '${w.lateToday ? ' · late today' : ''}',
          w.lateDaysThisWeek > 1 ? 'alert' : 'warning',
        ),
      ui.openButton('Open attendance', 'attendance'),
    ];
  }

  List<String> _overtime(_Ui ui, InsightData data) {
    final sorted = [...data.workers]
      ..sort((a, b) => b.workedToday.compareTo(a.workedToday));
    final over = sorted.where((w) => w.overtimeToday).length;
    return [
      ui.text('## Hours today'),
      ui.text(
        over == 0
            ? 'Nobody is over 8 hours today.'
            : '$over over 8 hours today.',
        caption: true,
      ),
      for (final w in sorted)
        if (w.workedToday > Duration.zero)
          ui.worker(
            w.name,
            _hours(w.workedToday) + (w.overtimeToday ? ' · overtime' : ''),
            w.overtimeToday ? 'warning' : 'neutral',
          ),
      if (sorted.every((w) => w.workedToday == Duration.zero))
        ui.text('No hours recorded yet today.'),
    ];
  }

  List<String> _leave(_Ui ui, InsightData data) {
    final away = data.workers.where((w) => w.onLeaveToday).toList();
    return [
      ui.text('## Leave'),
      ui.row([
        ui.stat('Waiting', data.pendingLeave,
            data.pendingLeave > 0 ? 'warning' : 'neutral'),
        ui.stat('Away today', away.length, 'neutral'),
      ]),
      for (final w in away) ui.worker(w.name, 'On leave today', 'neutral'),
      if (data.pendingLeave > 0)
        ui.openButton('Review leave requests', 'leave'),
    ];
  }

  List<String> _unknown(_Ui ui) => [
        ui.text('## I can answer these for now'),
        ui.text(
          'Who is on site now? · Who was late this week? · '
          'Hours and overtime today · Leave waiting for approval',
          caption: true,
        ),
      ];

  static String _hours(Duration d) =>
      '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
}

/// Collects components into A2UI's flat list and hands out their ids.
class _Ui {
  final components = <Map<String, Object?>>[];
  var _next = 0;

  String _add(Map<String, Object?> component) {
    final id = 'c${_next++}';
    components.add({'id': id, ...component});
    return id;
  }

  String text(String text, {bool caption = false}) => _add({
        'component': 'Text',
        'text': text,
        if (caption) 'variant': 'caption',
      });

  String row(List<String> children) =>
      _add({'component': 'Row', 'children': children});

  String stat(String label, int value, String tone) => _add({
        'component': 'StatTile',
        '@catalogId': trustPunchCatalogId,
        'label': label,
        'value': '$value',
        'tone': tone,
        'weight': 1,
      });

  String worker(String name, String detail, String tone) => _add({
        'component': 'WorkerRow',
        '@catalogId': trustPunchCatalogId,
        'name': name,
        'detail': detail,
        'tone': tone,
      });

  /// A button that asks the app to open one of [openableScreens]. It cannot
  /// approve, delete or change anything itself.
  String openButton(String label, String screen) {
    assert(openableScreens.contains(screen));
    final labelId = text(label);
    return _add({
      'component': 'Button',
      'child': labelId,
      'variant': 'primary',
      'action': {
        'event': {
          'name': 'open',
          'context': {'screen': screen},
        },
      },
    });
  }
}
