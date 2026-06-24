import 'dart:async';
import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _errorMessage;
  LlamaEngine? _engine;
  bool _stopRequested = false;

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

  void stop() => _stopRequested = true;

  Stream<String> chat(
    String userMessage, {
    List<Map<String, String>> history = const [],
    String systemPrompt = '',
    double temperature = 0.7,
    int maxTokens = 2048,
    double topP = 0.95,
    double repeatPenalty = 1.1,
  }) async* {
    if (_engine == null || !isReady) throw StateError('Model not loaded');
    _stopRequested = false;

    final messages = <LlamaChatMessage>[];

    if (systemPrompt.isNotEmpty) {
      messages.add(LlamaChatMessage(role: 'system', content: systemPrompt));
    }
    for (final h in history) {
      final content = h['content'] ?? '';
      if (content.isNotEmpty) {
        messages
            .add(LlamaChatMessage(role: h['role'] ?? 'user', content: content));
      }
    }
    messages.add(LlamaChatMessage(role: 'user', content: userMessage));

    try {
      await for (final chunk in _engine!.create(messages)) {
        if (_stopRequested) break;
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null && content.isNotEmpty) yield content;
      }
    } catch (_) {
      final buf = StringBuffer();
      if (systemPrompt.isNotEmpty) buf.writeln(systemPrompt);
      for (final h in history) {
        final role = h['role'] == 'assistant' ? 'Assistant' : 'User';
        final content = h['content'] ?? '';
        if (content.isNotEmpty) buf.writeln('$role: $content');
      }
      buf.write('User: $userMessage\nAssistant:');
      await for (final token in _engine!.generate(buf.toString())) {
        if (_stopRequested) break;
        yield token;
      }
    }
  }

  Future<void> unload() async {
    _engine?.dispose();
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
