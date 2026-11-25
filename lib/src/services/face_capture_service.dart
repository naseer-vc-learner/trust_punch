import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Owns the front camera and the ML Kit face detector.
///
/// There is deliberately no gallery picker anywhere in this app: every frame
/// that is analysed comes from a live camera stream started here.
class FaceCaptureService {
  CameraController? _controller;
  FaceDetector? _detector;
  bool _streaming = false;

  CameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('No camera available on this device.');

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    // ML Kit reads bgra8888 on iOS and nv21 on Android; anything else arrives
    // as a buffer it cannot decode.
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
        enableClassification: true, // eye-open probabilities, for blinks
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.2,
      ),
    );
  }

  Future<void> streamFaces(void Function(List<Face>) onFaces) async {
    final controller = _controller;
    final detector = _detector;
    if (controller == null || detector == null || _streaming) return;
    _streaming = true;

    var busy = false;
    await controller.startImageStream((image) async {
      // Drop frames rather than queue them: a backlog would report a blink
      // seconds after it happened.
      if (busy || !_streaming) return;
      busy = true;
      try {
        final input = _toInputImage(image, controller.description);
        if (input != null) onFaces(await detector.processImage(input));
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

  /// Takes the still that gets matched against the enrolled face. Called only
  /// after liveness passed, so the photo belongs to a session already proven
  /// to be a live person rather than a held-up picture.
  Future<String> capturePhoto() async {
    await stopStream();
    final controller = _controller;
    if (controller == null) throw StateError('Camera not initialised');
    final file = await controller.takePicture();
    return file.path;
  }

  Future<void> dispose() async {
    await stopStream();
    await _controller?.dispose();
    await _detector?.close();
    _controller = null;
    _detector = null;
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription camera) {
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (rotation == null || format == null) return null;

    // Both supported formats are single-plane as configured above. A
    // multi-plane buffer means the format negotiation silently changed, and
    // concatenating those planes would hand ML Kit garbage.
    if (image.planes.length != 1) return null;
    if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;
    if (Platform.isAndroid && format != InputImageFormat.nv21) return null;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }
}
