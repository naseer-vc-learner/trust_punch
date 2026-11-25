import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../capture/capture_screen.dart';

/// Shown when a WFH presence ping arrives.
///
/// The countdown is real: the server closes the window server-side, so an
/// employee who lets it run out is recorded as missing the ping regardless of
/// what this screen does. The timer exists to be honest about the deadline,
/// not to enforce it.
class PresencePingScreen extends ConsumerStatefulWidget {
  const PresencePingScreen({
    super.key,
    required this.pingId,
    required this.expiresAt,
  });

  final String pingId;
  final DateTime expiresAt;

  @override
  ConsumerState<PresencePingScreen> createState() => _PresencePingScreenState();
}

class _PresencePingScreenState extends ConsumerState<PresencePingScreen> {
  Timer? _ticker;
  late Duration _remaining = widget.expiresAt.difference(DateTime.now());

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining = widget.expiresAt.difference(DateTime.now()));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expired = _remaining.isNegative;
    final seconds = _remaining.inSeconds.clamp(0, 3600);

    return Scaffold(
      appBar: AppBar(title: const Text('Presence check')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              expired ? Icons.timer_off_outlined : Icons.timer_outlined,
              size: 64,
              color: expired ? Theme.of(context).colorScheme.error : null,
            ),
            const SizedBox(height: 20),
            Text(
              expired ? 'This check has expired' : 'Confirm you are working',
              key: const Key('ping-title'),
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              expired
                  ? 'The response window closed. It has been recorded as missed — '
                      'let your manager know if something went wrong.'
                  : 'Take a quick face capture within '
                      '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
                      '${(seconds % 60).toString().padLeft(2, '0')}.',
              key: const Key('ping-subtitle'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            if (!expired)
              FilledButton.icon(
                key: const Key('ping-respond'),
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => CaptureScreen(
                      type: AttendanceType.wfh,
                      pingId: widget.pingId,
                    ),
                  ),
                ),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Respond now'),
              )
            else
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
          ],
        ),
      ),
    );
  }
}
