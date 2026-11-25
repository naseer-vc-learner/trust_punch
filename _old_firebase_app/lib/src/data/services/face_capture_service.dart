import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Owns the front camera and the ML Kit detector.
///
/// There is deliberately no gallery picker anywhere in this app: every image
/// that reaches the server originates from a live camera stream started here.
/// An `image_picker` dependency would make a saved photo indistinguishable from
/// a capture, which would defeat the whole verification chain.
class FaceCaptureService {
  CameraController? _controller;
  FaceDetector? _detector;
  bool _streaming = false;

  CameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    await controller.initialize();
    _controller = controller;

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true, // eye-open probabilities
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.2,
      ),
    );
  }

  /// Streams detected faces until [stop] is called.
  Future<void> streamFaces(void Function(List<Face>) onFaces) async {
    final controller = _controller;
    final detector = _detector;
    if (controller == null || detector == null || _streaming) return;
    _streaming = true;

    var busy = false;
    await controller.startImageStream((image) async {
      // Drop frames rather than queue them: a backlog would let the detector
      // report a blink seconds after it happened.
      if (busy) return;
      busy = true;
      try {
        final input = _toInputImage(image, controller.description);
        if (input != null) {
          onFaces(await detector.processImage(input));
        }
      } catch (e) {
        debugPrint('Face detection frame failed: $e');
      } finally {
        busy = false;
      }
    });
  }

  Future<void> stopStream() async {
    if (!_streaming) return;
    _streaming = false;
    try {
      await _controller?.stopImageStream();
    } catch (_) {
      // Already stopped — nothing to unwind.
    }
  }

  /// Takes the still that gets submitted. Called only after liveness passed,
  /// so the bytes on the wire belong to a session we already proved was live.
  Future<Uint8List> captureStill() async {
    await stopStream();
    final controller = _controller;
    if (controller == null) throw StateError('Camera not initialised');
    final file = await controller.takePicture();
    return file.readAsBytes();
  }

  Future<void> dispose() async {
    await stopStream();
    await _controller?.dispose();
    await _detector?.close();
    _controller = null;
    _detector = null;
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription camera) {
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int? ?? 0);
    if (rotation == null || format == null || image.planes.isEmpty) return null;

    return InputImage.fromBytes(
      bytes: _concatPlanes(image.planes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Uint8List _concatPlanes(List<Plane> planes) {
    if (planes.length == 1) return planes.first.bytes;
    final builder = BytesBuilder(copy: false);
    for (final plane in planes) {
      builder.add(plane.bytes);
    }
    return builder.takeBytes();
  }
}
