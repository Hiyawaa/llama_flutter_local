import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _loadedMmprojPath;
  String? _errorMessage;
  LlamaEngine? _engine;
  bool _stopRequested = false;
  // Surface when chat() silently degraded to the raw-completion fallback
  // (no chat template applied) instead of hiding it in debug logs only.
  // Small/less-common models fed a template-free prompt can produce
  // degenerate output (run-on text, missing spaces, repetition) since
  // they're fine-tuned to expect their specific instruct format — that's
  // a plausible root cause for models like SmolVLM's text backbone
  // producing garbled text on turns where this fires. Read via
  // [lastTurnUsedFallback] right after a chat() stream completes.
  bool _lastTurnUsedFallback = false;

  ModelStatus get status => _status;
  String? get loadedPath => _loadedPath;
  String? get loadedMmprojPath => _loadedMmprojPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == ModelStatus.ready;
  bool get hasVision => _loadedMmprojPath != null;
  bool get lastTurnUsedFallback => _lastTurnUsedFallback;
  bool get stopRequested => _stopRequested;

  Future<void> loadModel(
    String path, {
    String? mmprojPath,
    int contextSize = 1024,
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
          debugPrint(
              'LlamaService Warning: Incompatible or faulty multimodal projector: $projError. Loading as standard text LLM.');
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
    // Kept for backward compatibility with existing callers.
    String? imagePath,
    // Feature 4 (Multi-Turn Vision): preferred over [imagePath] going
    // forward. If both are supplied, [imagePaths] wins.
    List<String>? imagePaths,
    // Feature 9 (JSON Mode): when true, we try to constrain decoding
    // structurally in addition to the prompt-level instruction the caller
    // already folds into [systemPrompt].
    bool jsonMode = false,
    // Fast/Thinking toggle: when true, reasoning-capable models (Qwen3
    // and similar) are allowed to emit their internal chain-of-thought
    // before the final answer. This was previously hardcoded to false —
    // llamadart already exposes it, it just wasn't surfaced anywhere.
    // Thinking mode uses meaningfully more tokens per turn since the
    // reasoning trace itself consumes generation budget before the
    // actual answer starts.
    bool enableThinking = false,
  }) async* {
    if (_engine == null || !isReady) throw StateError('Model not loaded');
    _stopRequested = false;
    _lastTurnUsedFallback = false;
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

    final effectiveImages = (imagePaths != null && imagePaths.isNotEmpty)
        ? imagePaths.where((p) => p.trim().isNotEmpty).toList()
        : (imagePath != null && imagePath.trim().isNotEmpty
            ? [imagePath]
            : const <String>[]);

    final hasImage = effectiveImages.isNotEmpty;

    if (hasImage) {
      if (!hasVision) {
        throw StateError(
          'No mmproj is loaded. Load a matching vision projector before '
          'sending images.',
        );
      }
      // llamadart's public API in this project version is confirmed to
      // accept a single LlamaImageContent per message reliably. We
      // optimistically try attaching all provided images to one message
      // (some llama.cpp mmproj backends do support multiple images per
      // turn), but fall back to just the first image if the engine
      // rejects a multi-image content list — better to lose extra images
      // than to crash the turn entirely, especially on constrained
      // hardware where vision inference is already the most memory-heavy
      // path in the app.
      try {
        messages.add(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaTextContent(userMessage),
              ...effectiveImages
                  .map((path) => LlamaImageContent(path: path.trim())),
            ],
          ),
        );
      } catch (_) {
        messages.add(
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaTextContent(userMessage),
              LlamaImageContent(path: effectiveImages.first.trim()),
            ],
          ),
        );
      }
    } else {
      messages.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: userMessage,
        ),
      );
    }

    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: jsonMode ? temperature.clamp(0.0, 0.4) : temperature,
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
        enableThinking: enableThinking,
      )) {
        if (_stopRequested) break;
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null && content.isNotEmpty) yield content;
      }
    } catch (e) {
      if (hasImage) rethrow;
      _lastTurnUsedFallback = true;
      // Surface why the templated chat call failed instead of silently
      // degrading — otherwise "the AI response looks wrong" is
      // undiagnosable, since this fallback skips the model's chat
      // template entirely and free-hands a plain-text prompt.
      debugPrint('LlamaService Warning: engine.create failed, falling back to '
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
        temp: jsonMode ? temperature.clamp(0.0, 0.4) : temperature,
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
          '<|eot_id|>',
          '<|end_of_text|>',
          '<|im_end|>',
          '<end_of_turn>',
          '</s>',
          '<|end|>',
          '<|endoftext|>',
          '\nUser:',
          '\nUser :',
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

  /// Feature 9 helper: runs [chat] to completion and validates the result
  /// actually parses as JSON. This project's llamadart version doesn't
  /// expose a confirmed GBNF/grammar-constrained decoding hook, so true
  /// token-level JSON constraint isn't available here — instead we rely
  /// on the prompt-level instruction (set by the caller's systemPrompt)
  /// plus a single bounded retry with a corrective follow-up if the first
  /// attempt doesn't parse. This is a best-effort measure, not a hard
  /// guarantee, and callers should still handle a FormatException.
  Future<String> chatJsonOnce(
    String userMessage, {
    List<Map<String, String>> history = const [],
    String systemPrompt = '',
    double temperature = 0.2,
    int maxTokens = 512,
    double topP = 0.95,
    double repeatPenalty = 1.1,
  }) async {
    Future<String> attempt(
        String prompt, List<Map<String, String>> hist) async {
      final buf = StringBuffer();
      await for (final token in chat(
        prompt,
        history: hist,
        systemPrompt: systemPrompt,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        repeatPenalty: repeatPenalty,
        jsonMode: true,
      )) {
        buf.write(token);
      }
      return buf.toString().trim();
    }

    final first = await attempt(userMessage, history);
    try {
      jsonDecode(first);
      return first;
    } catch (_) {
      // One corrective retry, explicitly pointing out the failure rather
      // than silently repeating the same malformed output.
      final retryHistory = [
        ...history,
        {'role': 'user', 'content': userMessage},
        {'role': 'assistant', 'content': first},
      ];
      final retry = await attempt(
        'Your previous response was not valid JSON. Respond again with '
        'ONLY a single valid JSON value, no prose, no code fences.',
        retryHistory,
      );
      return retry;
    }
  }

  /// Feature 1 (KV-Cache persistence): best-effort session save/restore.
  ///
  /// The llamadart version pinned in pubspec.yaml (^0.8.1) does not have a
  /// *confirmed* public API for raw KV-cache/session serialization in this
  /// codebase's usage so far — calling straight into `_engine!.saveSession`
  /// would be a compile-time gamble if that method doesn't exist. We probe
  /// for it via dynamic dispatch instead: if the underlying engine exposes
  /// a session save/restore method, we use it; if not, this returns false
  /// and callers (see kv_cache_service.dart) fall back to conversation-text
  /// replay, which is slower to "warm up" but always works.
  Future<bool> trySaveSessionTo(String path) async {
    if (_engine == null) return false;
    try {
      final dynamic engine = _engine;
      await engine.saveSession(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> tryLoadSessionFrom(String path) async {
    if (_engine == null) return false;
    try {
      final dynamic engine = _engine;
      await engine.loadSession(path);
      return true;
    } catch (_) {
      return false;
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
