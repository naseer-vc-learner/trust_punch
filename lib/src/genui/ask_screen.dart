import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../screens/calendar_screen.dart';
import '../screens/leave_screen.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'ask_engine.dart';
import 'insight_data.dart';
import 'trustpunch_catalog.dart';

const _suggestions = [
  'Who is on site now?',
  'Who was late this week?',
  'Hours and overtime today',
  'Leave waiting for approval',
];

/// How many answers stay on screen; older ones are deleted.
const _keepAnswers = 5;

/// The supervisor asks in plain words; the answer is drawn as generated UI.
///
/// Answers are A2UI messages rendered by `a2ui_flutter` from two catalogs:
/// the basic one and [trustPunchCatalog]. They can show data and offer to
/// open a screen from [openableScreens] — nothing else. Approving leave or
/// deleting data still happens on the normal screens, by a person's tap.
class AskScreen extends StatefulWidget {
  const AskScreen({
    super.key,
    required this.store,
    required this.lock,
    this.engine = const ScriptedAskEngine(),
  });

  final AttendanceStore store;
  final SupervisorLock lock;
  final AskEngine engine;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _Answer {
  _Answer(this.question, this.surface);

  final String question;
  final SurfaceModel<ComponentImplementation> surface;
}

class _AskScreenState extends State<AskScreen> {
  final _processor = newAskProcessor();
  final _input = TextEditingController();
  final _questions = <String, String>{};
  final _answers = <_Answer>[];
  final _subscriptions = <Subscription>[];
  var _next = 0;
  var _busy = false;

  String get _lang => widget.store.languageCode;

  @override
  void initState() {
    super.initState();
    final model = _processor.model;
    _subscriptions
      ..add(model.onSurfaceCreated.subscribe((surface) {
        setState(() => _answers.insert(
              0,
              _Answer(_questions[surface.id] ?? '', surface),
            ));
      }))
      ..add(model.onSurfaceDeleted.subscribe((id) {
        setState(() => _answers.removeWhere((a) => a.surface.id == id));
        _questions.remove(id);
      }))
      ..add(model.onAction.subscribe(_onAction));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.unsubscribe();
    }
    _processor.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    setState(() => _busy = true);
    _input.clear();

    final surfaceId = 'answer-${_next++}';
    _questions[surfaceId] = q;
    try {
      final messages = await widget.engine.answer(
        q,
        InsightData.from(widget.store),
        surfaceId: surfaceId,
      );
      _processor.processMessages(messages);
      _trim();
    } on A2uiError catch (error) {
      // An answer that fails validation is refused whole, never half-drawn.
      debugPrint('A2UI ${error.code}: ${error.message}');
      _questions.remove(surfaceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t(_lang, T.askCouldNotShow))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _trim() {
    while (_answers.length > _keepAnswers) {
      _processor.processMessages([
        {
          'version': '1.0',
          'deleteSurface': {'surfaceId': _answers.last.surface.id},
        },
      ]);
    }
  }

  /// The only thing an answer can make the app do: open an allowed screen.
  void _onAction(A2uiRendererAction action) {
    final screen = action.context['screen'];
    if (action.name != 'open' || !openableScreens.contains(screen)) {
      debugPrint('Ask: ignored action ${action.name} $screen');
      return;
    }
    final store = widget.store;
    final lock = widget.lock;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => switch (screen) {
        'leave' => LeaveScreen(store: store, lock: lock, canDecide: true),
        _ => CalendarScreen(store: store, lock: lock, canDelete: true),
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t(_lang, T.ask))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Icon(Icons.offline_bolt_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t(_lang, T.askOffline),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _input,
              enabled: !_busy,
              textInputAction: TextInputAction.send,
              onSubmitted: _ask,
              decoration: InputDecoration(
                hintText: t(_lang, T.askHint),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: t(_lang, T.ask),
                  icon: const Icon(Icons.send),
                  onPressed: _busy ? null : () => _ask(_input.text),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in _suggestions)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      label: Text(s),
                      onPressed: _busy ? null : () => _ask(s),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final answer in _answers)
                  Card(
                    key: ObjectKey(answer.surface),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            answer.question,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(fontStyle: FontStyle.italic),
                          ),
                          const SizedBox(height: 8),
                          A2uiSurface(surface: answer.surface),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
