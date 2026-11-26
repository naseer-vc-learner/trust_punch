import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/attendance.dart';

/// Cosine similarity a live face must reach against an enrolled angle.
///
/// MobileFaceNet embeddings put the same person well above this and different
/// people well below it; the gap is wide enough that the exact number only
/// matters at the margins. Raise it to make matching stricter.
const double faceMatchThreshold = 0.65;

/// How far ahead of the runner-up the winner must be, when several people are
/// enrolled on one phone.
///
/// Identifying against N faces is far riskier than confirming one: every extra
/// worker is another chance to be the closest match by accident. A clear
/// winner is required, and a near-tie is refused rather than guessed at.
const double faceMatchMargin = 0.06;

/// Similarity at which a new enrollment is treated as someone already on the
/// roster.
///
/// Deliberately looser than [faceMatchThreshold]: the cost of wrongly refusing
/// a registration is a retry, while the cost of letting one face hold two
/// identities is a worker who can be in two places — the exact fraud this app
/// exists to stop.
const double faceDuplicateThreshold = 0.58;

class Identification {
  const Identification({required this.worker, required this.score, this.runnerUp});

  final Worker worker;
  final double score;
  final double? runnerUp;
}

/// Turns a photo of a face into an embedding, so two faces can be compared
/// without any of the images ever leaving the device.
class FaceRecognizer {
  Interpreter? _interpreter;
  FaceDetector? _detector;

  late int _inputSize;
  late int _embeddingSize;

  bool get isReady => _interpreter != null;

  Future<void> load() async {
    if (_interpreter != null) return;

    final interpreter =
        await Interpreter.fromAsset('assets/models/mobilefacenet.tflite');

    // Read the geometry off the model rather than hardcoding it, so swapping
    // in a different embedding model doesn't silently produce garbage.
    final inputShape = interpreter.getInputTensor(0).shape;
    final outputShape = interpreter.getOutputTensor(0).shape;
    _inputSize = inputShape[1];
    _embeddingSize = outputShape.last;

    debugPrint('FaceRecognizer: input $inputShape output $outputShape');

    _interpreter = interpreter;
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );
  }

  /// Picks which enrolled worker this embedding belongs to, or null when no
  /// one is a clear enough match.
  Identification? identify(List<double> embedding, List<Worker> workers) {
    if (workers.isEmpty) return null;

    final scored = workers
        .map((w) => (w, w.bestSimilarity(embedding)))
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));

    final best = scored.first;
    if (best.$2 < faceMatchThreshold) return null;

    final runnerUp = scored.length > 1 ? scored[1].$2 : null;
    if (runnerUp != null && best.$2 - runnerUp < faceMatchMargin) return null;

    return Identification(
      worker: best.$1,
      score: best.$2,
      runnerUp: runnerUp,
    );
  }

  /// The already-enrolled worker these new angles belong to, if any.
  Worker? findDuplicate(List<List<double>> embeddings, List<Worker> existing) {
    for (final worker in existing) {
      for (final embedding in embeddings) {
        if (worker.bestSimilarity(embedding) >= faceDuplicateThreshold) {
          return worker;
        }
      }
    }
    return null;
  }

  Future<void> dispose() async {
    _interpreter?.close();
    await _detector?.close();
    _interpreter = null;
    _detector = null;
  }

  /// Embeds the largest face in [photoPath], or null if no face is found.
  Future<List<double>?> embedFromPhoto(String photoPath) async {
    final interpreter = _interpreter;
    final detector = _detector;
    if (interpreter == null || detector == null) {
      throw StateError('FaceRecognizer.load() was not awaited');
    }

    final raw = img.decodeImage(await File(photoPath).readAsBytes());
    if (raw == null) return null;

    // ML Kit applies EXIF orientation but the decoder above does not, so the
    // bounding box would land on a rotated copy. Bake the rotation in and
    // detect against that same baked file to keep one coordinate space.
    final upright = img.bakeOrientation(raw);
    final bakedPath = await _writeTemp(upright);
    final List<Face> faces;
    try {
      faces = await detector.processImage(InputImage.fromFilePath(bakedPath));
    } finally {
      // A full-size face photo must not be left behind on disk.
      await _deleteQuietly(bakedPath);
    }
    if (faces.isEmpty) return null;

    final face = faces.reduce((a, b) =>
        a.boundingBox.width * a.boundingBox.height >
                b.boundingBox.width * b.boundingBox.height
            ? a
            : b);

    final crop = _cropFace(upright, face);
    final resized =
        img.copyResize(crop, width: _inputSize, height: _inputSize);

    return _runModel(interpreter, resized);
  }

  List<double> _runModel(Interpreter interpreter, img.Image face) {
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final pixel = face.getPixel(x, y);
          // MobileFaceNet expects pixels centred on zero.
          return [
            (pixel.r - 127.5) / 128.0,
            (pixel.g - 127.5) / 128.0,
            (pixel.b - 127.5) / 128.0,
          ];
        }),
      ),
    );

    final output = [List<double>.filled(_embeddingSize, 0)];
    interpreter.run(input, output);

    return _l2Normalize(output.first);
  }

  /// Crops to the face with a margin, since a tight ML Kit box clips the chin
  /// and hairline the model was trained to see.
  img.Image _cropFace(img.Image source, Face face) {
    final box = face.boundingBox;
    final margin = box.width * 0.2;

    final left = (box.left - margin).clamp(0, source.width - 1).toInt();
    final top = (box.top - margin).clamp(0, source.height - 1).toInt();
    final right = (box.right + margin).clamp(0, source.width).toInt();
    final bottom = (box.bottom + margin).clamp(0, source.height).toInt();

    return img.copyCrop(
      source,
      x: left,
      y: top,
      width: math.max(1, right - left),
      height: math.max(1, bottom - top),
    );
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Deletes a camera photo once it has been used, so full-size face photos
  /// never pile up in the app's cache (MASVS-STORAGE / PRIVACY).
  static Future<void> discardPhoto(String path) => _deleteQuietly(path);

  Future<String> _writeTemp(img.Image image) async {
    final file = File('${Directory.systemTemp.path}/face_upright.jpg');
    await file.writeAsBytes(img.encodeJpg(image, quality: 92));
    return file.path;
  }

  static List<double> _l2Normalize(List<double> vector) {
    var sum = 0.0;
    for (final v in vector) {
      sum += v * v;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return vector;
    return vector.map((v) => v / norm).toList();
  }
}
