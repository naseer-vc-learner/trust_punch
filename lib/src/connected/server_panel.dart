import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../screens/supervisor_pin.dart';
import '../services/supervisor_lock.dart';
import '../store/attendance_store.dart';
import 'punch_sync.dart';
import 'server_api.dart';

/// The server line under the role picker of the connected app: whether the
/// server answers, how many punches wait, and the way to pair the phone.
///
/// English-only, like the supervisor screens. Pairing needs the code the
/// server prints; unpairing needs the supervisor PIN.
class ServerPanel extends StatelessWidget {
  const ServerPanel({
    super.key,
    required this.sync,
    required this.store,
    required this.lock,
  });

  /// Null when this build was given no server address.
  final PunchSync? sync;
  final AttendanceStore store;
  final SupervisorLock lock;

  @override
  Widget build(BuildContext context) {
    final sync = this.sync;
    if (sync == null) {
      return const _Line(
        icon: Icons.cloud_off_outlined,
        color: Colors.grey,
        text: 'Connected app without a server address '
            '(build with --dart-define=API_BASE_URL=…)',
      );
    }
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (icon, color, text) = _summary(sync);
        return _Line(
          icon: icon,
          color: color,
          text: text,
          onTap: () => _details(context, sync),
        );
      },
    );
  }

  static (IconData, Color, String) _summary(PunchSync sync) {
    final waiting = sync.waiting;
    final problem = sync.problem;
    final health = sync.health;
    if (!sync.paired) {
      return (
        Icons.link_off,
        Colors.orange,
        'Server: not paired · $waiting waiting · tap to pair',
      );
    }
    if (problem != null) {
      return (
        Icons.cloud_off_outlined,
        Colors.orange,
        'Server: ${problem.message} · $waiting waiting — '
            'punching still works',
      );
    }
    if (health != null && !health.ok) {
      return (
        Icons.cloud_off_outlined,
        Colors.orange,
        'Server: ${health.error} · $waiting waiting',
      );
    }
    final last = sync.lastSent;
    return (
      sync.busy ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined,
      Colors.green,
      waiting == 0
          ? 'Server: all sent'
              '${last == null ? '' : ' · ${DateFormat('HH:mm').format(last)}'}'
          : 'Server: $waiting waiting',
    );
  }

  Future<void> _details(BuildContext context, PunchSync sync) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Grows to its content, so the buttons are never hidden below it.
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final health = sync.health;
          final clock = health?.clockDifference;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                Text('Server', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(sync.api.baseUrl.toString()),
                const SizedBox(height: 12),
                _Fact('Answers', health == null
                    ? 'checking…'
                    : health.ok
                        ? 'yes · ${health.roundTrip?.inMilliseconds} ms'
                        : 'no · ${health.error}'),
                if (clock != null)
                  _Fact('Phone clock',
                      clock.inSeconds.abs() < 2
                          ? 'in step with the server'
                          : 'off by ${clock.inSeconds.abs()} s'),
                _Fact('Paired', sync.paired ? 'yes' : 'no'),
                _Fact('Waiting to send', '${sync.waiting}'),
                if (sync.refused > 0)
                  _Fact('Refused by server', '${sync.refused}'),
                if (sync.flags.isNotEmpty)
                  _Fact('Flagged by server (this session)',
                      '${sync.flags.length}'),
                if (sync.lastOutcome case final o?) ...[
                  const SizedBox(height: 12),
                  // The answer to "Send now", so a tap never looks ignored.
                  Card(
                    color: o.problem == null
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      dense: true,
                      leading: Icon(o.problem == null
                          ? Icons.check_circle_outline
                          : Icons.error_outline),
                      title: Text(o.summary),
                      subtitle: Text(
                          'Last try ${DateFormat('HH:mm:ss').format(o.at)}'),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (!sync.paired)
                  FilledButton.icon(
                    onPressed: () => _pair(context, sync),
                    icon: const Icon(Icons.link),
                    label: const Text('Pair with server'),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: sync.busy
                        ? null
                        : () async {
                            await sync.checkHealth();
                            await sync.syncNow();
                          },
                    icon: sync.busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined),
                    label: Text(sync.busy ? 'Sending…' : 'Send now'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final lang = store.languageCode;
                      if (await requireSupervisor(context, lock, lang)) {
                        await sync.unpair();
                      }
                    },
                    icon: const Icon(Icons.link_off),
                    label: const Text('Unpair this phone'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pair(BuildContext context, PunchSync sync) async {
    final messenger = ScaffoldMessenger.of(context);
    // The dialog owns its text fields, and frees them only once it has
    // finished closing: they are still on screen during that animation.
    final answer = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _PairDialog(),
    );
    if (answer == null) return;
    final (codeText, nameText) = answer;
    try {
      await sync.pair(codeText, nameText.isEmpty ? 'Phone' : nameText);
      messenger.showSnackBar(const SnackBar(content: Text('Paired')));
    } on ServerException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(switch (e.problem) {
          ServerProblem.refused => 'Code not valid — ask for a new one',
          ServerProblem.tooManyAttempts =>
            'Too many wrong codes — wait 10 minutes',
          ServerProblem.invalid => 'The code is 6 digits',
          _ => 'Could not pair: ${e.message}',
        }),
      ));
    }
  }
}

/// Code and phone name; pops with both, or null on Cancel.
class _PairDialog extends StatefulWidget {
  const _PairDialog();

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Gate phone');

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pair with server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the 6-digit code the server shows '
                '(run-dev.sh prints one; it works once, for 10 minutes).'),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'Pairing code'),
            ),
            TextField(
              controller: _name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Name this phone'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              (_code.text, _name.text.trim()),
            ),
            child: const Text('Pair'),
          ),
        ],
      );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.color,
    required this.text,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(text, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
