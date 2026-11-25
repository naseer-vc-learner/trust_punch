import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/providers.dart';
import '../../data/models/models.dart';
import '../capture/capture_screen.dart';
import '../wfh/wfh_screen.dart';
import '../admin/admin_dashboard.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employee = ref.watch(currentEmployeeProvider);
    final integrity = ref.watch(deviceIntegrityProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('TrustPunch'),
        actions: [
          if (employee.valueOrNull?.isAdmin ?? false)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: 'Admin',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminDashboard()),
              ),
            ),
        ],
      ),
      body: employee.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load your profile.\n$e')),
        data: (emp) {
          if (emp == null) {
            return const Center(child: Text('No employee record found.'));
          }
          final blocked = integrity.valueOrNull?.isCompromised ?? false;
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myAttendanceProvider);
              ref.invalidate(pendingSubmissionsProvider);
              ref.invalidate(openSessionProvider);
              await ref.read(attendanceRepositoryProvider).flushQueue();
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Greeting(employee: emp),
                if (blocked) const _CompromisedDeviceBanner(),
                const _PendingBanner(),
                const _SessionCard(),
                const SizedBox(height: 8),
                _SiteDistanceCard(employee: emp),
                const SizedBox(height: 16),
                _CheckInActions(employee: emp, blocked: blocked),
                const SizedBox(height: 24),
                Text('Recent activity',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const _RecentRecords(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(employee.name.isEmpty ? 'Welcome' : employee.name,
              style: Theme.of(context).textTheme.headlineSmall),
          Text(
            DateFormat('EEEE, d MMMM').format(DateTime.now()),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// Root/jailbreak block. Shown, not hidden: an employee who cannot punch in
/// deserves to know why before they walk to the office.
class _CompromisedDeviceBanner extends StatelessWidget {
  const _CompromisedDeviceBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('compromised-device-banner'),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.gpp_bad_outlined, color: scheme.onErrorContainer),
        title: Text('Attendance blocked on this device',
            style: TextStyle(color: scheme.onErrorContainer)),
        subtitle: Text(
          'This device appears to be rooted, jailbroken or emulated. '
          'Contact IT to use a managed device.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

/// Unconfirmed captures. The wording never implies the punch counted.
class _PendingBanner extends ConsumerWidget {
  const _PendingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingSubmissionsProvider).valueOrNull ?? const [];
    if (pending.isEmpty) return const SizedBox.shrink();

    return Card(
      key: const Key('pending-banner'),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.cloud_off_outlined),
        title: Text('${pending.length} check-in(s) not yet confirmed'),
        subtitle: const Text(
          'Captured offline. These are NOT approved until the server confirms them.',
        ),
        trailing: TextButton(
          onPressed: () async {
            await ref.read(attendanceRepositoryProvider).flushQueue();
            ref.invalidate(pendingSubmissionsProvider);
            ref.invalidate(myAttendanceProvider);
          },
          child: const Text('Retry'),
        ),
      ),
    );
  }
}

/// Live distance readout. Display only — the server recomputes it.
class _SiteDistanceCard extends ConsumerWidget {
  const _SiteDistanceCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(assignedSitesProvider).valueOrNull ?? const <Site>[];
    if (sites.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.location_off_outlined),
          title: Text('No site assigned'),
          subtitle: Text('Only work-from-home check-in is available.'),
        ),
      );
    }

    final site = sites.first;
    return Card(
      child: StreamBuilder<double>(
        stream: ref.watch(locationServiceProvider).distanceToSite(
              siteLatitude: site.latitude,
              siteLongitude: site.longitude,
            ),
        builder: (context, snapshot) {
          final distance = snapshot.data;
          final inside = distance != null && distance <= site.radiusMeters;
          return ListTile(
            leading: Icon(
              inside ? Icons.my_location : Icons.location_searching,
              color: inside ? const Color(0xFF2E7D32) : null,
            ),
            title: Text(site.name),
            subtitle: Text(
              distance == null
                  ? 'Locating…'
                  : '${distance.round()} m away · boundary ${site.radiusMeters.round()} m',
            ),
            trailing: distance == null
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(inside ? 'Inside' : 'Outside'),
          );
        },
      ),
    );
  }
}

/// Live status of the working day: when you arrived, hours so far, breaks used.
class _SessionCard extends ConsumerWidget {
  const _SessionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(openSessionProvider).valueOrNull;
    if (session == null) return const SizedBox.shrink();

    final onBreak = session.status == SessionStatus.onBreak;
    final worked = session.elapsedWorked;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('session-card'),
      color: onBreak ? scheme.tertiaryContainer : scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(onBreak ? Icons.free_breakfast_outlined : Icons.work_history_outlined),
                const SizedBox(width: 8),
                Text(
                  onBreak ? 'On break' : 'Working',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text('since ${DateFormat('HH:mm').format(session.checkInAt)}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Metric(
                  label: 'Worked',
                  value: '${worked.inHours}h ${(worked.inMinutes % 60).toString().padLeft(2, '0')}m',
                ),
                const SizedBox(width: 24),
                _Metric(
                  label: 'Break used',
                  value: '${session.totalBreakMinutes}m of 60m',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      );
}

/// Offers only the transitions that are legal right now.
///
/// The server enforces the same state machine and rejects anything illegal, but
/// showing an impossible button and then refusing it would be a poor way to
/// teach someone how the day works.
class _CheckInActions extends ConsumerWidget {
  const _CheckInActions({required this.employee, required this.blocked});

  final Employee employee;
  final bool blocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(assignedSitesProvider).valueOrNull ?? const <Site>[];
    final session = ref.watch(openSessionProvider).valueOrNull;
    final status = session?.status ?? SessionStatus.none;
    final onsite = sites.isNotEmpty;

    void go(AttendanceDirection direction, AttendanceType type) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CaptureScreen(
            type: type,
            direction: direction,
            siteId: type == AttendanceType.onsite ? sites.first.id : null,
          ),
        ),
      );
    }

    if (status == SessionStatus.none || status == SessionStatus.closed) {
      return Column(
        children: [
          FilledButton.icon(
            key: const Key('checkin-onsite'),
            onPressed: blocked || !onsite
                ? null
                : () => go(AttendanceDirection.checkIn, AttendanceType.onsite),
            icon: const Icon(Icons.business_outlined),
            label: const Text('Check in on-site'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('checkin-wfh'),
            onPressed:
                blocked ? null : () => go(AttendanceDirection.checkIn, AttendanceType.wfh),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.home_work_outlined),
            label: const Text('Check in from home'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const WfhScreen())),
            icon: const Icon(Icons.event_available_outlined),
            label: const Text('Work-from-home days'),
          ),
        ],
      );
    }

    // Mid-day: the check-in already established whether this is on-site or WFH,
    // so the remaining punches inherit it rather than asking again.
    final type = onsite ? AttendanceType.onsite : AttendanceType.wfh;
    final onBreak = status == SessionStatus.onBreak;

    return Column(
      children: [
        FilledButton.icon(
          key: const Key('checkout'),
          onPressed: blocked ? null : () => go(AttendanceDirection.checkOut, type),
          icon: const Icon(Icons.logout),
          label: const Text('Check out'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: Key(onBreak ? 'break-end' : 'break-start'),
          onPressed: blocked
              ? null
              : () => go(
                    onBreak ? AttendanceDirection.breakEnd : AttendanceDirection.breakStart,
                    type,
                  ),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: Icon(onBreak ? Icons.play_arrow_outlined : Icons.free_breakfast_outlined),
          label: Text(onBreak ? 'End break' : 'Start break'),
        ),
      ],
    );
  }
}

class _RecentRecords extends ConsumerWidget {
  const _RecentRecords();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(myAttendanceProvider);
    final scheme = Theme.of(context).colorScheme;

    return records.when(
      loading: () => const Center(child: Padding(
        padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      error: (e, _) => Text('Could not load records: $e'),
      data: (items) {
        if (items.isEmpty) {
          return const Card(
            child: ListTile(title: Text('No check-ins yet.')),
          );
        }
        return Column(
          children: [
            for (final record in items)
              Card(
                child: ListTile(
                  leading: Icon(record.status.icon, color: record.status.color(scheme)),
                  title: Text(
                    '${record.type == AttendanceType.wfh ? 'Work from home' : 'On-site'}'
                    ' · ${record.status.label}',
                  ),
                  subtitle: Text(
                    '${DateFormat('d MMM, HH:mm').format(record.timestamp)}'
                    '${record.distanceFromSite != null ? ' · ${record.distanceFromSite!.round()} m from site' : ''}'
                    '${record.flagReason != null ? '\n${record.flagReason!.nextStep}' : ''}',
                  ),
                  isThreeLine: record.flagReason != null,
                ),
              ),
          ],
        );
      },
    );
  }
}
