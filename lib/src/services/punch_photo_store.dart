import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Keeps a small selfie for each punch, as evidence of who checked in.
///
/// Only a reduced copy is kept (at most [_maxWidth] px wide, JPEG quality
/// [_quality]), in the app's private support folder. The full-size camera
/// photo is deleted by the caller as soon as it has been used.
///
/// Privacy: these are photos of faces. They stay on this phone, are shown
/// only in the calendar and the punch result, and are deleted with "Delete
/// all attendance". Android backup is off for the app (see the manifest);
/// iOS backup exclusion is not done yet.
class PunchPhotoStore {
  PunchPhotoStore(this._dir);

  static const _maxWidth = 360;
  static const _quality = 70;

  static Future<PunchPhotoStore>? _shared;

  /// The app-wide store, opened on first use.
  static Future<PunchPhotoStore> shared() => _shared ??= () async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory('${base.path}/punch_photos');
        await dir.create(recursive: true);
        return PunchPhotoStore(dir);
      }();

  /// Lets tests use a temporary folder instead of the real one.
  @visibleForTesting
  static void debugUse(PunchPhotoStore? store) =>
      _shared = store == null ? null : Future.value(store);

  final Directory _dir;

  File fileFor(String name) => File('${_dir.path}/$name');

  /// Saves [jpeg] for [workerId] at [at]; returns the file name to put on
  /// the punch.
  Future<String> save(
    Uint8List jpeg, {
    required String workerId,
    required DateTime at,
  }) async {
    // Only digits, letters, '-' and '_' reach the file name.
    final safeId = workerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final name = '${safeId}_${at.microsecondsSinceEpoch}.jpg';
    await fileFor(name).writeAsBytes(jpeg, flush: true);
    return name;
  }

  Future<void> deleteAll() async {
    if (!await _dir.exists()) return;
    await for (final entity in _dir.list()) {
      if (entity is File) await entity.delete();
    }
  }

  /// A reduced, upright JPEG of the photo at [photoPath], made off the UI
  /// thread. Null if the photo cannot be read.
  static Future<Uint8List?> thumbnailOf(String photoPath) async {
    final bytes = await File(photoPath).readAsBytes();
    return compute(_shrink, bytes);
  }

  static Uint8List? _shrink(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    final small = upright.width > _maxWidth
        ? img.copyResize(upright, width: _maxWidth)
        : upright;
    return img.encodeJpg(small, quality: _quality);
  }
}
