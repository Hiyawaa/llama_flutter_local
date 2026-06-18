import 'dart:async';
import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _errorMessage;
  LlamaEngine? _engine;

  ModelStatus get status => _status;
  String? get loadedPath => _loadedPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == ModelStatus.ready;

  Future<void> loadModel(String path,
      {int contextSize = 2048, int threads = 4}) async {
    await unload();
    _status = ModelStatus.loading;
    _errorMessage = null;

    try {
      _engine = LlamaEngine(LlamaBackend());
      await _engine!.loadModel(path);
      _loadedPath = path;
      _status = ModelStatus.ready;
    } catch (e) {
      _status = ModelStatus.error;
      _errorMessage = e.toString();
      _engine = null;
      rethrow;
    }
  }

  Stream<String> chat(
    String userMessage, {
    String systemPrompt = '',
    double temperature = 0.7,
    int maxTokens = 2048,
    double topP = 0.95,
    double repeatPenalty = 1.1,
  }) async* {
    if (_engine == null || !isReady) {
      throw StateError('Model not loaded');
    }

    try {
      // Use ChatSession for proper system prompt + chat template support
      final session = ChatSession(
        _engine!,
        systemPrompt: systemPrompt.isNotEmpty ? systemPrompt : null,
      );

      await for (final chunk in session.create([
        LlamaTextContent(userMessage),
      ])) {
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null && content.isNotEmpty) {
          yield content;
        }
      }
    } catch (_) {
      // Fallback: raw generate if ChatSession isn't available
      final prompt = systemPrompt.isNotEmpty
          ? '$systemPrompt\n\nUser: $userMessage\nAssistant:'
          : userMessage;
      await for (final token in _engine!.generate(prompt)) {
        yield token;
      }
    }
  }

  Future<void> unload() async {
    await _engine?.dispose();
    _engine = null;
    _status = ModelStatus.unloaded;
    _loadedPath = null;
    _errorMessage = null;
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
  }
}
