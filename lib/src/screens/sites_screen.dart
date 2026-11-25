import 'package:flutter/material.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/location_service.dart';
import '../store/attendance_store.dart';

/// Manages the set of work locations a shift can happen at.
class SitesScreen extends StatefulWidget {
  const SitesScreen({super.key, required this.store});

  final AttendanceStore store;

  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  bool _busy = false;

  Future<void> _addHere() async {
    final name = await _askName();
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final fix = await LocationService().currentFix();
      // A site saved from a vague fix puts its centre in the wrong place, and
      // every later check-in there is judged against that wrong centre.
      if (!fix.isPrecise) {
        if (mounted) {
          _snack('${t(widget.store.languageCode, T.weakLocation)} '
              '(±${fix.accuracyMeters.round()} m)');
        }
        return;
      }
      await widget.store.addSite(Site(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        latitude: fix.latitude,
        longitude: fix.longitude,
      ));
      if (mounted) _snack('Saved "$name" at your current location.');
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(widget.store.languageCode, T.nameThisSite)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Head office, Warehouse, Client A…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t(widget.store.languageCode, T.cancel)),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: Text(t(widget.store.languageCode, T.save)),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(widget.store.languageCode, T.workSites))),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final sites = widget.store.sites;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Add every location a shift can happen at. On check-in the '
                  'app picks whichever one you are standing in, within '
                  '${geofenceRadiusMeters.round()} m.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Expanded(
                child: sites.isEmpty
                    ? Center(
                        child: Text(t(widget.store.languageCode, T.noSitesYet)))
                    : ListView.builder(
                        itemCount: sites.length,
                        itemBuilder: (context, i) {
                          final site = sites[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            child: ListTile(
                              leading: const Icon(Icons.business),
                              title: Text(site.name),
                              subtitle: Text(
                                '${site.latitude.toStringAsFixed(5)}, '
                                '${site.longitude.toStringAsFixed(5)}',
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    widget.store.removeSite(site.id),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _busy ? null : _addHere,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_location_alt),
                  label: Text(t(widget.store.languageCode, T.addCurrentLocation)),
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
