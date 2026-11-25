import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/providers.dart';
import '../../data/models/models.dart';

/// The outcome screen.
///
/// Every word on it comes from the server's verdict. The `queued` variant is a
/// separate constructor rather than a flag, so it is not possible to render an
/// unconfirmed capture with approved styling by passing the wrong boolean.
class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key, required this.outcome, this.pingId});

  const ResultScreen.queued({super.key})
      : outcome = null,
        pingId = null;

  final CheckInOutcome? outcome;

  /// When set, this capture was answering a WFH presence ping.
  final String? pingId;

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  @override
  void initState() {
    super.initState();
    final outcome = widget.outcome;
    final pingId = widget.pingId;
    if (outcome != null && pingId != null) {
      // Close the ping out with the record id the server just issued.
      ref.read(apiProvider).respondToPresencePing(
            pingId: pingId,
            attendanceRecordId: outcome.recordId,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outcome = widget.outcome;
    final status = outcome?.status ?? AttendanceStatus.pendingSync;

    return Scaffold(
      appBar: AppBar(title: const Text('Check-in result')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Icon(status.icon, size: 72, color: status.color(scheme)),
            const SizedBox(height: 16),
            Text(
              status.label,
              key: const Key('result-status'),
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: status.color(scheme)),
            ),
            const SizedBox(height: 12),
            Text(
              outcome?.message ??
                  'Captured without a connection. This is not approved yet — '
                      'it will be sent for verification when you are back online.',
              key: const Key('result-message'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (outcome?.flagReason != null) ...[
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('What to do next'),
                  subtitle: Text(
                    outcome!.flagReason!.nextStep,
                    key: const Key('result-next-step'),
                  ),
                ),
              ),
            ],
            if (outcome?.distanceFromSiteMeters != null) ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: const Text('Distance from site'),
                  subtitle:
                      Text('${outcome!.distanceFromSiteMeters!.round()} metres'),
                ),
              ),
            ],
            const Spacer(),
            if (outcome?.flagReason?.isRetryable ?? outcome == null)
              FilledButton(
                key: const Key('result-retry'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Try again'),
              ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const Key('result-done'),
              onPressed: () {
                ref.invalidate(myAttendanceProvider);
                ref.invalidate(pendingSubmissionsProvider);
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
