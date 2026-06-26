import 'dart:async';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

// ── Result models ─────────────────────────────────────────────────────────────

class MlKitLabel {
  final String label;
  final double confidence; // 0.0–1.0

  const MlKitLabel(this.label, this.confidence);

  int get percent => (confidence * 100).round();

  // FIX: Added split method to delegate to the underlying label string.
  // This prevents the "method 'split' isn't defined" error if the object is treated as a string.
  List<String> split(Pattern pattern) => label.split(pattern);

  // FIX: Added toString override just in case the object is passed into a Text widget
  // or string interpolation directly.
  @override
  String toString() => label;
}

class MlKitResult {
  final String? recognizedText; // OCR output
  final List<MlKitLabel> labels; // structured image labels
  final List<String> barcodes; // barcode/QR values
  final String? error; // human-readable, may combine multiple failures
  final Duration duration;

  MlKitResult({
    this.recognizedText,
    this.labels = const [],
    this.barcodes = const [],
    this.error,
    required this.duration,
  });

  bool get hasText =>
      recognizedText != null && recognizedText!.trim().isNotEmpty;
  bool get hasLabels => labels.isNotEmpty;
  bool get hasBarcodes => barcodes.isNotEmpty;
  bool get hasError => error != null;
  bool get isEmpty => !hasText && !hasLabels && !hasBarcodes;
}

// ── Service ───────────────────────────────────────────────────────────────────

class MlKitService {
  TextRecognizer? _textRecognizer;
  ImageLabeler? _imageLabeler;
  BarcodeScanner? _barcodeScanner;

  bool _initialized = false;
  TextRecognitionScript _currentScript = TextRecognitionScript.latin;

  /// (Re)initializes the recognizers. Only recreates the text recognizer
  /// if the requested script differs from the one currently loaded —
  /// labeler/barcode scanner are cheap to keep around once created.
  void _init({TextRecognitionScript script = TextRecognitionScript.latin}) {
    final needsTextRecognizerSwap = !_initialized || script != _currentScript;

    if (needsTextRecognizerSwap) {
      _textRecognizer?.close();
      _textRecognizer = TextRecognizer(script: script);
      _currentScript = script;
    }

    if (!_initialized) {
      _imageLabeler = ImageLabeler(
        options: ImageLabelerOptions(confidenceThreshold: 0.60),
      );
      _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);
      _initialized = true;
    }
  }

  /// Runs all enabled analyses in parallel and returns combined results.
  /// Each analyzer's failure is isolated — one crashing doesn't wipe out
  /// results already produced by the others.
  Future<MlKitResult> analyzeImage(
    String imagePath, {
    bool doOcr = true,
    bool doLabeling = true,
    bool doBarcode = true,
    TextRecognitionScript script = TextRecognitionScript.latin,
  }) async {
    _init(script: script);
    final sw = Stopwatch()..start();

    String? recognizedText;
    final labels = <MlKitLabel>[];
    final barcodes = <String>[];
    final errors = <String>[];

    final inputImage = InputImage.fromFilePath(imagePath);

    Future<void> safely(String tag, Future<void> Function() run) async {
      try {
        await run();
      } catch (e) {
        errors.add('$tag: $e');
      }
    }

    final futures = <Future<void>>[];

    if (doOcr && _textRecognizer != null) {
      futures.add(safely('OCR', () async {
        final r = await _textRecognizer!.processImage(inputImage);
        final text = r.text.trim();
        if (text.isNotEmpty) recognizedText = text;
      }));
    }

    if (doLabeling && _imageLabeler != null) {
      futures.add(safely('Labeling', () async {
        final r = await _imageLabeler!.processImage(inputImage);
        for (final lbl in r) {
          labels.add(MlKitLabel(lbl.label, lbl.confidence));
        }
      }));
    }

    if (doBarcode && _barcodeScanner != null) {
      futures.add(safely('Barcode', () async {
        final r = await _barcodeScanner!.processImage(inputImage);
        for (final bc in r) {
          if (bc.displayValue != null) barcodes.add(bc.displayValue!);
        }
      }));
    }

    try {
      await Future.wait(futures).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      errors.add('Scan timed out — try a smaller image or retry');
    }

    sw.stop();
    return MlKitResult(
      recognizedText: recognizedText,
      labels: labels,
      barcodes: barcodes,
      error: errors.isEmpty ? null : errors.join('; '),
      duration: sw.elapsed,
    );
  }

  void dispose() {
    _textRecognizer?.close();
    _imageLabeler?.close();
    _barcodeScanner?.close();
    _initialized = false;
  }
}
