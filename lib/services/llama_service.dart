import 'dart:async';
import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _errorMessage;
  LlamadartModel? _model;

  ModelStatus get status => _status;
  String? get loadedPath => _loadedPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == ModelStatus.ready;

  Future<void> loadModel(
    String path, {
    int contextSize = 2048,
    int threads = 4,
  }) async {
    await unload();
    _status = ModelStatus.loading;
    _errorMessage = null;

    try {
      _model = await LlamadartModel.load(
        path,
        contextSize: contextSize,
        threads: threads,
      );
      _loadedPath = path;
      _status = ModelStatus.ready;
    } catch (e) {
      _status = ModelStatus.error;
      _errorMessage = e.toString();
      _model = null;
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
    if (_model == null || _status != ModelStatus.ready) {
      throw StateError('Model not loaded');
    }

    final prompt = systemPrompt.isNotEmpty
        ? '$systemPrompt\n\nUser: $userMessage\nAssistant:'
        : userMessage;

    yield* _model!.generate(
      prompt,
      temperature: temperature,
      maxTokens: maxTokens,
      topP: topP,
      repeatPenalty: repeatPenalty,
    );
  }

  Future<void> unload() async {
    _model?.dispose();
    _model = null;
    _status = ModelStatus.unloaded;
    _loadedPath = null;
    _errorMessage = null;
  }

  void dispose() {
    _model?.dispose();
    _model = null;
  }
}
