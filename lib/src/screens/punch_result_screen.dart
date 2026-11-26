import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n/ui_text.dart';
import '../models/attendance.dart';
import '../services/punch_photo_store.dart';

const _green = Color(0xFF2E7D32);
const _red = Color(0xFFC62828);

/// The whole screen turns green after a punch: who, what, where, when, and
/// the photo just taken. Readable from a distance and without reading — the
/// colour and the tick say it worked.
///
/// Closes itself after [showFor] (or on any tap), so a gate phone is ready
/// for the next person without anyone touching it.
class PunchSuccessScreen extends StatefulWidget {
  const PunchSuccessScreen({
    super.key,
    required this.lang,
    required this.workerName,
    required this.type,
    required this.siteName,
    required this.at,
    this.photo,
    this.autoCheckout,
    this.showFor = const Duration(seconds: 5),
  });

  final String lang;
  final String workerName;
  final PunchType type;
  final String siteName;
  final DateTime at;
  final Uint8List? photo;

  /// "Gate A: automatic check-out at 11:50", when moving location closed
  /// another one.
  final String? autoCheckout;
  final Duration showFor;

  @override
  State<PunchSuccessScreen> createState() => _PunchSuccessScreenState();
}

class _PunchSuccessScreenState extends State<PunchSuccessScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.showFor, _close);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _close() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    final action = t(lang, switch (widget.type) {
      PunchType.checkIn => T.checkInLabel,
      PunchType.checkOut => T.checkOutLabel,
      PunchType.breakStart => T.onBreak,
      PunchType.breakEnd => T.checkedIn,
    });
    final photo = widget.photo;
    const white = Colors.white;

    return Scaffold(
      backgroundColor: _green,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 72,
                      backgroundColor: Colors.white24,
                      backgroundImage:
                          photo == null ? null : MemoryImage(photo),
                      child: photo == null
                          ? const Icon(Icons.person, size: 72, color: white)
                          : null,
                    ),
                    const CircleAvatar(
                      radius: 26,
                      backgroundColor: white,
                      child: Icon(Icons.check, size: 36, color: _green),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  widget.workerName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  action,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: white, fontSize: 24),
                ),
                const SizedBox(height: 16),
                Text(
                  '${widget.siteName} · ${DateFormat('HH:mm').format(widget.at)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 20),
                ),
                if (widget.autoCheckout != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_horiz, color: white),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.autoCheckout!,
                            style: const TextStyle(color: white, fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                // Shows how long until the screen closes by itself.
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: widget.showFor,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value,
                    color: white,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _close,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: white,
                      side: const BorderSide(color: white),
                    ),
                    child: Text(
                      t(lang, T.close),
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The selfie kept with [punch], as a small round thumbnail. Tap to see it
/// larger with who, where and when. Draws an icon if the file is missing.
class PunchPhotoThumb extends StatefulWidget {
  const PunchPhotoThumb({super.key, required this.punch, this.size = 40});

  final Punch punch;
  final double size;

  @override
  State<PunchPhotoThumb> createState() => _PunchPhotoThumbState();
}

class _PunchPhotoThumbState extends State<PunchPhotoThumb> {
  // Looked up once per photo, not on every rebuild of the list around it.
  late Future<File?> _file = _find();

  @override
  void didUpdateWidget(PunchPhotoThumb old) {
    super.didUpdateWidget(old);
    if (old.punch.photo != widget.punch.photo) _file = _find();
  }

  Future<File?> _find() async {
    final name = widget.punch.photo;
    if (name == null) return null;
    final file = (await PunchPhotoStore.shared()).fileFor(name);
    return await file.exists() ? file : null;
  }

  @override
  Widget build(BuildContext context) {
    final punch = widget.punch;
    final size = widget.size;
    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return SizedBox.square(
            dimension: size,
            child: const Icon(Icons.image_not_supported_outlined),
          );
        }
        return InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.file(file, fit: BoxFit.contain),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${punch.workerName} · ${punch.siteName} · '
                      '${DateFormat('d MMM HH:mm').format(punch.at)}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: CircleAvatar(
            radius: size / 2,
            backgroundImage: ResizeImage(
              FileImage(file),
              width: (size * 2).round(),
            ),
          ),
        );
      },
    );
  }
}

/// The whole screen turns red when a punch is refused, with the reason and
/// a way to try again. Nothing was recorded.
class PunchFailureView extends StatelessWidget {
  const PunchFailureView({
    super.key,
    required this.message,
    required this.lang,
    required this.onRetry,
    required this.onClose,
  });

  final String message;
  final String lang;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return Scaffold(
      backgroundColor: _red,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const CircleAvatar(
                radius: 72,
                backgroundColor: Colors.white24,
                child: Icon(Icons.close, size: 96, color: white),
              ),
              const SizedBox(height: 24),
              Text(
                t(lang, T.couldNotVerify),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (message.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: white, fontSize: 18),
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: white,
                    foregroundColor: _red,
                  ),
                  child: Text(
                    t(lang, T.tryAgain),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  onPressed: onClose,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: white,
                    side: const BorderSide(color: white),
                  ),
                  child: Text(
                    t(lang, T.close),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
