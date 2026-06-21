import 'dart:async';
import 'package:llamadart/llamadart.dart';

enum VisionStatus { unloaded, loading, ready, error }

class VisionService {
  LlamaEngine? _engine;
  VisionStatus _status = VisionStatus.unloaded;
  String? _modelPath;
  String? _mmprojPath;
  String? _errorMessage;

  VisionStatus get status => _status;
  String? get modelPath => _modelPath;
  String? get mmprojPath => _mmprojPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == VisionStatus.ready;

  bool _stopRequested = false;

  Future<void> loadModel(
    String modelPath,
    String mmprojPath, {
    int contextSize = 4096,
    int threads = 4,
  }) async {
    await unload();
    _status = VisionStatus.loading;
    _errorMessage = null;

    try {
      _engine = LlamaEngine(LlamaBackend());
      await _engine!.loadModel(modelPath);
      // Load the multimodal projector (vision encoder)
      await _engine!.loadMultimodalProjector(mmprojPath);

      _modelPath = modelPath;
      _mmprojPath = mmprojPath;
      _status = VisionStatus.ready;
    } catch (e) {
      _status = VisionStatus.error;
      _errorMessage = e.toString();
      _engine = null;
      rethrow;
    }
  }

  void stop() => _stopRequested = true;

  /// Analyse an image with an optional text prompt.
  /// [imagePath] must be a local file path (JPEG or PNG).
  Stream<String> analyzeImage(
    String imagePath, {
    String prompt = 'Describe this image in detail.',
    double temperature = 0.3,
    int maxTokens = 1024,
  }) async* {
    if (_engine == null || !isReady) {
      throw StateError('Vision model not loaded');
    }
    _stopRequested = false;

    final messages = [
      LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          LlamaImageContent(path: imagePath),
          LlamaTextContent(prompt),
        ],
      ),
    ];

    final response = _engine!.create(messages);
    await for (final chunk in response) {
      if (_stopRequested) break;
      final content = chunk.choices.firstOrNull?.delta.content;
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  /// Chat with image context — keeps the image in context for follow-up Qs
  Stream<String> chatWithImage(
    String imagePath,
    List<Map<String, String>> history, // [{role, content}]
    String newMessage, {
    double temperature = 0.3,
    int maxTokens = 1024,
  }) async* {
    if (_engine == null || !isReady) {
      throw StateError('Vision model not loaded');
    }
    _stopRequested = false;

    final messages = <LlamaChatMessage>[];

    // First message always includes the image
    messages.add(LlamaChatMessage.withContent(
      role: LlamaChatRole.user,
      content: [
        LlamaImageContent(path: imagePath),
        LlamaTextContent(
            history.isNotEmpty ? history.first['content'] ?? '' : newMessage),
      ],
    ));

    // Add remaining history as plain text
    for (int i = 1; i < history.length; i++) {
      final h = history[i];
      final role = h['role'] == 'assistant' ? 'assistant' : 'user';
      messages.add(LlamaChatMessage(role: role, content: h['content'] ?? ''));
    }

    // Add new user message if history was provided
    if (history.isNotEmpty) {
      messages.add(LlamaChatMessage(role: 'user', content: newMessage));
    }

    final response = _engine!.create(messages);
    await for (final chunk in response) {
      if (_stopRequested) break;
      final content = chunk.choices.firstOrNull?.delta.content;
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  Future<void> unload() async {
    _engine?.dispose();
    _engine = null;
    _status = VisionStatus.unloaded;
    _modelPath = null;
    _mmprojPath = null;
    _errorMessage = null;
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
  }
}
