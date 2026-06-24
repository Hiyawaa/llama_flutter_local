import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

// ── Result models ─────────────────────────────────────────────────────────────

class MlKitResult {
  final String? recognizedText; // OCR output
  final List<String> labels; // image labels with confidence
  final List<String> barcodes; // barcode/QR values
  final String? error;
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

  void _init() {
    if (_initialized) return;
    _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _imageLabeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.60),
    );
    _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);
    _initialized = true;
  }

  /// Run all three analyses in parallel and return combined results.
  Future<MlKitResult> analyzeImage(
    String imagePath, {
    bool doOcr = true,
    bool doLabeling = true,
    bool doBarcode = true,
  }) async {
    _init();
    final sw = Stopwatch()..start();
    String? recognizedText;
    final labels = <String>[];
    final barcodes = <String>[];
    String? error;

    final inputImage = InputImage.fromFilePath(imagePath);

    try {
      // Run all enabled analyses in parallel
      final futures = <Future>[];

      if (doOcr && _textRecognizer != null) {
        futures.add(
          _textRecognizer!.processImage(inputImage).then((r) {
            final text = r.text.trim();
            if (text.isNotEmpty) recognizedText = text;
          }),
        );
      }

      if (doLabeling && _imageLabeler != null) {
        futures.add(
          _imageLabeler!.processImage(inputImage).then((r) {
            for (final lbl in r) {
              final pct = (lbl.confidence * 100).toStringAsFixed(0);
              labels.add('${lbl.label} ($pct%)');
            }
          }),
        );
      }

      if (doBarcode && _barcodeScanner != null) {
        futures.add(
          _barcodeScanner!.processImage(inputImage).then((r) {
            for (final bc in r) {
              if (bc.displayValue != null) barcodes.add(bc.displayValue!);
            }
          }),
        );
      }

      await Future.wait(futures);
    } catch (e) {
      error = e.toString();
    }

    sw.stop();
    return MlKitResult(
      recognizedText: recognizedText,
      labels: labels,
      barcodes: barcodes,
      error: error,
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
