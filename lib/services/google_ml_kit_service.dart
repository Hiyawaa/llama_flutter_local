import 'dart:async';
import 'package:google_ml_kit/google_ml_kit.dart';

class GoogleMLKitService {
  late TextRecognizer _textRecognizer;
  late FaceDetector _faceDetector;
  late ObjectDetector _objectDetector;

  GoogleMLKitService() {
    _textRecognizer = GoogleMlKit.vision.textRecognizer();
    _faceDetector = GoogleMlKit.vision.faceDetector();
    _objectDetector = GoogleMlKit.vision.objectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );
  }

  /// Extract text from an image using ML Kit text recognition
  Future<String> recognizeText(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      await inputImage.close();
      return recognizedText.text;
    } catch (e) {
      throw Exception('Text recognition failed: $e');
    }
  }

  /// Detect faces in an image
  Future<List<Face>> detectFaces(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final faces = await _faceDetector.processImage(inputImage);
      await inputImage.close();
      return faces;
    } catch (e) {
      throw Exception('Face detection failed: $e');
    }
  }

  /// Detect objects in an image
  Future<List<DetectedObject>> detectObjects(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final objects = await _objectDetector.processImage(inputImage);
      await inputImage.close();
      return objects;
    } catch (e) {
      throw Exception('Object detection failed: $e');
    }
  }

  /// Analyze image with multiple ML Kit features
  Future<Map<String, dynamic>> analyzeImage(String imagePath) async {
    try {
      final text = await recognizeText(imagePath);
      final faces = await detectFaces(imagePath);
      final objects = await detectObjects(imagePath);

      return {
        'text': text,
        'faceCount': faces.length,
        'objectCount': objects.length,
        'objects': objects
            .map((o) => {
                  'label': o.labels.isNotEmpty ? o.labels.first.text : 'Unknown',
                  'confidence':
                      o.labels.isNotEmpty ? o.labels.first.confidence : 0.0,
                })
            .toList(),
      };
    } catch (e) {
      throw Exception('Image analysis failed: $e');
    }
  }

  void dispose() {
    _textRecognizer.close();
    _faceDetector.close();
    _objectDetector.close();
  }
}
