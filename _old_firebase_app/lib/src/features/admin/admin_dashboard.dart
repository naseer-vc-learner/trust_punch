import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../data/models/models.dart';

/// Minimal admin view — works on Flutter web as-is.
///
/// It reads across all employees, which the security rules permit only for a
/// token carrying `admin: true`. Approvals are performed through Cloud
/// Functions, not direct writes, so the same server-side checks apply whether
/// the actor is an app or an administrator.
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Administration'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Flagged', icon: Icon(Icons.flag_outlined)),
            Tab(text: 'Devices', icon: Icon(Icons.smartphone_outlined)),
            Tab(text: 'Sites', icon: Icon(Icons.place_outlined)),
          ]),
        ),
        body: const TabBarView(children: [
          _FlaggedQueue(),
          _DeviceApprovalQueue(),
          _SiteList(),
        ]),
      ),
    );
  }
}

class _FlaggedQueue extends ConsumerWidget {
  const _FlaggedQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref
        .watch(firestoreProvider)
        .collection('attendance')
        .where('status', isEqualTo: 'flagged')
        .orderBy('timestamp', descending: true)
        .limit(100);

    return _QueryList(
      query: query,
      emptyLabel: 'No flagged records.',
      itemBuilder: (context, doc) {
        final data = doc.data();
        final reason = FlagReason.fromCode(data['flagReason'] as String?);
        final all = (data['allFlagReasons'] as List<dynamic>? ?? const [])
            .map((r) => FlagReason.fromCode(r as String).name)
            .join(', ');
        final timestamp = (data['timestamp'] as Timestamp?)?.toDate();

        return Card(
          child: ListTile(
            leading: const Icon(Icons.flag_outlined, color: Color(0xFFEF6C00)),
            title: Text('${data['employeeId']} · ${reason.name}'),
            subtitle: Text([
              if (timestamp != null) DateFormat('d MMM y, HH:mm').format(timestamp),
              'score ${((data['faceMatchScore'] as num?) ?? 0).toStringAsFixed(3)}',
              if (data['distanceFromSite'] != null)
                '${(data['distanceFromSite'] as num).round()} m from site',
              if (data['isMockLocationFlag'] == true) 'MOCK LOCATION',
              if (data['deviceTrusted'] == false) 'untrusted device',
              if (all.isNotEmpty) 'all: $all',
            ].join(' · ')),
            isThreeLine: true,
            // Even an admin cannot write to `attendance` directly — the rules
            // deny it, so the review goes through a callable like everything
            // else that touches the record.
            trailing: TextButton(
              onPressed: () => ref
                  .read(apiProvider)
                  .reviewAttendanceRecord(recordId: doc.id, accepted: true),
              child: const Text('Mark reviewed'),
            ),
          ),
        );
      },
    );
  }
}

class _DeviceApprovalQueue extends ConsumerWidget {
  const _DeviceApprovalQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref
        .watch(firestoreProvider)
        .collection('devices')
        .where('approved', isEqualTo: false)
        .orderBy('registeredAt', descending: true)
        .limit(100);

    return _QueryList(
      query: query,
      emptyLabel: 'No devices awaiting approval.',
      itemBuilder: (context, doc) {
        final data = doc.data();
        return Card(
          child: ListTile(
            leading: const Icon(Icons.smartphone_outlined),
            title: Text('${data['model']} (${data['platform']})'),
            subtitle: Text('Employee: ${data['employeeId']}\nDevice: ${doc.id}'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Reject',
                  icon: const Icon(Icons.close),
                  onPressed: () => ref
                      .read(apiProvider)
                      .approveDevice(deviceId: doc.id, approve: false),
                ),
                IconButton(
                  tooltip: 'Approve',
                  icon: const Icon(Icons.check),
                  onPressed: () => ref
                      .read(apiProvider)
                      .approveDevice(deviceId: doc.id, approve: true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SiteList extends ConsumerWidget {
  const _SiteList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(firestoreProvider).collection('sites').limit(100);

    return _QueryList(
      query: query,
      emptyLabel: 'No sites configured. Add them from the Firebase console or an '
          'admin-only Cloud Function — client writes to `sites` are denied.',
      itemBuilder: (context, doc) {
        final site = Site.fromDoc(doc);
        return Card(
          child: ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(site.name),
            subtitle: Text(
              '${site.latitude.toStringAsFixed(5)}, ${site.longitude.toStringAsFixed(5)}'
              ' · radius ${site.radiusMeters.round()} m',
            ),
          ),
        );
      },
    );
  }
}

class _QueryList extends StatelessWidget {
  const _QueryList({
    required this.query,
    required this.emptyLabel,
    required this.itemBuilder,
  });

  final Query<Map<String, dynamic>> query;
  final String emptyLabel;
  final Widget Function(BuildContext, QueryDocumentSnapshot<Map<String, dynamic>>)
      itemBuilder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load: ${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(emptyLabel, textAlign: TextAlign.center),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [for (final doc in docs) itemBuilder(context, doc)],
        );
      },
    );
  }
}
