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
      
      // Wrap the multimodal projector load in its own try-catch block
      // If loading the projector fails, the app falls back to standard text model execution
      if (mmprojPath != null && mmprojPath.trim().isNotEmpty) {
        try {
          await _engine!.loadMultimodalProjector(mmprojPath.trim());
          _loadedMmprojPath = mmprojPath.trim();
        } catch (projError) {
          // Fall back gracefully rather than crashing the text loading sequence
          print('LlamaService Warning: Incompatible or faulty multimodal projector: $projError. Loading as standard text LLM.');
          _loadedMmprojPath = null;
        }
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
      messages.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: systemPrompt,
        ),
      );
    }
    for (final h in history) {
      final content = h['content'] ?? '';
      if (content.isNotEmpty) {
        final role = (h['role'] ?? 'user').toLowerCase();
        final llamaRole = role == 'assistant'
            ? LlamaChatRole.assistant
            : role == 'system'
                ? LlamaChatRole.system
                : LlamaChatRole.user;
        messages.add(
          LlamaChatMessage.fromText(role: llamaRole, text: content),
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
      messages.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: userMessage,
        ),
      );
    }
    final hasImage = imagePath != null && imagePath.trim().isNotEmpty;
    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: temperature,
      topP: topP,
      penalty: repeatPenalty,
      topK: 40,
      minP: 0.05,
      streamBatchTokenThreshold: 4,
      streamBatchByteThreshold: 256,
      // Different GGUF chat templates use different end-of-turn markers.
      // Only matching Llama-3 tokens means models built on ChatML, Gemma,
      // Mistral, or Phi templates never see a stop match and keep
      // generating past their answer (rambling, or hallucinating a new
      // "User:" turn). Listing all common ones is harmless for models
      // that don't use them — unmatched strings simply never trigger.
      stopSequences: const [
        '<|eot_id|>', '<|end_of_text|>', // Llama 3.x
        '<|im_end|>', // ChatML / Qwen
        '<end_of_turn>', // Gemma
        '</s>', // Mistral / Llama 2
        '<|end|>', '<|endoftext|>', // Phi
      ],
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
    } catch (e) {
      if (hasImage) rethrow;
      // Surface why the templated chat call failed instead of silently
      // degrading — otherwise "the AI response looks wrong" is
      // undiagnosable, since this fallback skips the model's chat
      // template entirely and free-hands a plain-text prompt.
      print('LlamaService Warning: engine.create failed, falling back to '
          'raw completion: $e');
      final buf = StringBuffer();
      if (systemPrompt.isNotEmpty) buf.writeln(systemPrompt);
      for (final h in history) {
        final role = h['role'] == 'assistant' ? 'Assistant' : 'User';
        final content = h['content'] ?? '';
        if (content.isNotEmpty) buf.writeln('$role: $content');
      }
      buf.write('User: $userMessage\nAssistant:');
      final rawParams = GenerationParams(
        maxTokens: maxTokens,
        temp: temperature,
        topP: topP,
        penalty: repeatPenalty,
        topK: 40,
        minP: 0.05,
        streamBatchTokenThreshold: 4,
        streamBatchByteThreshold: 256,
        // This path has no chat template, so the model is prone to
        // inventing a new "User:" turn and answering itself. Cut it off
        // there in addition to the token-based stops above.
        stopSequences: const [
          '<|eot_id|>', '<|end_of_text|>',
          '<|im_end|>', '<end_of_turn>', '</s>',
          '<|end|>', '<|endoftext|>',
          '\nUser:', '\nUser :',
        ],
      );
      await for (final token in _engine!.generate(
        buf.toString(),
        params: rawParams,
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