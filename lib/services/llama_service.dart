import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _loadedMmprojPath;
  String? _errorMessage;
  LlamaEngine? _engine;
  bool _stopRequested = false;

  ModelStatus get status => _status;
  String? get loadedPath => _loadedPath;
  String? get loadedMmprojPath => _loadedMmprojPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == ModelStatus.ready;
  bool get hasVision => _loadedMmprojPath != null;
  bool get stopRequested => _stopRequested;

  Future<void> loadModel(
    String path, {
    String? mmprojPath,
    int contextSize = 2048,
    int threads = 0,
  }) async {
    await unload();
    _status = ModelStatus.loading;
    _errorMessage = null;
    try {
      _engine = LlamaEngine(LlamaBackend());
      await _engine!.loadModel(
        path,
        modelParams: ModelParams(
          contextSize: contextSize,
          numberOfThreads: threads,
          numberOfThreadsBatch: threads,
        ),
      );
      if (mmprojPath != null && mmprojPath.trim().isNotEmpty) {
        await _engine!.loadMultimodalProjector(mmprojPath.trim());
        _loadedMmprojPath = mmprojPath.trim();
      }
      _loadedPath = path;
      _status = ModelStatus.ready;
    } catch (e) {
      _status = ModelStatus.error;
      _errorMessage = e.toString();
      _engine = null;
      _loadedMmprojPath = null;
      rethrow;
    }
  }

  Stream<String> chat(
    String userMessage, {
    List<Map<String, String>> history = const [],
    String systemPrompt = '',
    double temperature = 0.7,
    int maxTokens = 512,
    double topP = 0.95,
    double repeatPenalty = 1.1,
    String? imagePath,
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
        messages.add(
          LlamaChatMessage(role: h['role'] ?? 'user', content: content),
        );
      }
    }

    if (imagePath != null && imagePath.trim().isNotEmpty) {
      if (!hasVision) {
        throw StateError(
          'No mmproj is loaded. Load a matching vision projector before '
          'sending images.',
        );
      }
      messages.add(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: [
            LlamaTextContent(userMessage),
            LlamaImageContent(path: imagePath.trim()),
          ],
        ),
      );
    } else {
      messages.add(LlamaChatMessage(role: 'user', content: userMessage));
    }

    final hasImage = imagePath != null && imagePath.trim().isNotEmpty;
    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topP: topP,
      penalty: repeatPenalty,
      streamBatchTokenThreshold: 4,
      streamBatchByteThreshold: 256,
    );

    try {
      await for (final chunk in _engine!.create(
        messages,
        params: params,
        enableThinking: false,
      )) {
        if (_stopRequested) break;
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null && content.isNotEmpty) yield content;
      }
    } catch (_) {
      if (hasImage) rethrow;
      final buf = StringBuffer();
      if (systemPrompt.isNotEmpty) buf.writeln(systemPrompt);
      for (final h in history) {
        final role = h['role'] == 'assistant' ? 'Assistant' : 'User';
        final content = h['content'] ?? '';
        if (content.isNotEmpty) buf.writeln('$role: $content');
      }
      buf.write('User: $userMessage\nAssistant:');
      await for (final token in _engine!.generate(
        buf.toString(),
        params: params,
      )) {
        if (_stopRequested) break;
        yield token;
      }
    }
  }

  Future<void> unload() async {
    await _engine?.dispose();
    _engine = null;
    _status = ModelStatus.unloaded;
    _loadedPath = null;
    _loadedMmprojPath = null;
    _errorMessage = null;
  }

  void stop() {
    _stopRequested = true;
    _engine?.cancelGeneration();
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
    _loadedMmprojPath = null;
  }
}
