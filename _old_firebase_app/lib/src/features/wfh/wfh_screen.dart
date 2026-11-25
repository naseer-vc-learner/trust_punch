import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';

/// Work-from-home days.
///
/// The employee *requests*; a manager approves. The toggle deliberately does
/// not grant WFH by itself, because a WFH day switches off the geofence — if
/// employees could grant it to themselves, location verification would be
/// optional in practice.
class WfhScreen extends ConsumerStatefulWidget {
  const WfhScreen({super.key});

  @override
  ConsumerState<WfhScreen> createState() => _WfhScreenState();
}

class _WfhScreenState extends ConsumerState<WfhScreen> {
  DateTime _date = DateTime.now();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(apiProvider)
          .requestWfhDay(date: _date, reason: _reason.text.trim());
      setState(() => _message =
          'Request sent. Your manager must approve it before you can check in from home.');
      _reason.clear();
    } catch (e) {
      setState(() => _message = 'Could not send the request: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final employeeId = ref.watch(currentEmployeeIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Work from home')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Date'),
              subtitle: Text(DateFormat('EEEE, d MMMM y').format(_date)),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 60)),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                child: const Text('Change'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            key: const Key('wfh-reason'),
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('wfh-submit'),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Sending…' : 'Request this day'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, key: const Key('wfh-message')),
          ],
          const SizedBox(height: 24),
          Text('Approved days', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (employeeId != null) _ApprovedDays(employeeId: employeeId),
        ],
      ),
    );
  }
}

class _ApprovedDays extends ConsumerWidget {
  const _ApprovedDays({required this.employeeId});
  final String employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref
        .watch(firestoreProvider)
        .collection('wfh_exceptions')
        .where('employeeId', isEqualTo: employeeId)
        .orderBy('date', descending: true)
        .limit(20);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Could not load approved days: ${snapshot.error}');
        }
        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const Card(child: ListTile(title: Text('No approved days yet.')));
        }
        return Column(
          children: [
            for (final doc in docs)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(doc.data()['date'] as String? ?? ''),
                  subtitle: Text(doc.data()['reason'] as String? ?? ''),
                ),
              ),
          ],
        );
      },
    );
  }
}
