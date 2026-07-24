import 'dart:io';
import 'package:llamadart/llamadart.dart';
import 'package:synchronized/synchronized.dart';
import 'ram_guard_service.dart';

/// Feature 3 (RAG) support service.
///
/// On a 4GB device, a chat model (often 1-4GB resident) and an embedding
/// model loaded at the same time is a near-guaranteed OOM. This service
/// therefore owns its OWN LlamaEngine instance, completely separate from
/// LlamaService, and the golden rule enforced here is:
///
///   The chat model and the embedding model are NEVER loaded at the same
///   time. Whoever wants to run must ask the other to unload first.
///
/// ChatProvider/RagService are responsible for calling
/// `EmbeddingService.prepareToEmbed(unloadChatModel)` before indexing or
/// querying, and reloading the chat model afterward if the user resumes
/// chatting. The [Lock] here only guards this service's own internal
/// engine lifecycle against concurrent calls; the cross-service handoff
/// (unloading the chat model) has to be orchestrated by the caller since
/// this service has no reference to LlamaService by design (keeps the
/// dependency direction one-way and easy to reason about).
class EmbeddingService {
  LlamaEngine? _engine;
  String? _loadedModelPath;
  final Lock _lock = Lock();

  bool get isReady => _engine != null;
  String? get loadedModelPath => _loadedModelPath;

  /// Loads the dedicated embedding GGUF model. Call this only after the
  /// caller has confirmed (and ideally unloaded) the chat model — this
  /// method still performs its own RAM check as a backstop, but it can't
  /// unload the chat model itself since it doesn't hold a reference to it.
  Future<void> load(String modelPath) async {
    await _lock.synchronized(() async {
      if (_loadedModelPath == modelPath && _engine != null) return;
      await _unloadInternal();

      final file = File(modelPath);
      if (!await file.exists()) {
        throw StateError('Embedding model not found at $modelPath');
      }
      final sizeBytes = await file.length();
      final estimateMb = (sizeBytes / (1024 * 1024)).ceil() + 150;
      await RamGuard.ensureCanLoad(estimateMb,
          operation: 'load the embedding model');

      final engine = LlamaEngine(LlamaBackend());
      // Embedding models are typically small (encoder-only, often
      // <200MB at Q8) and only need a short context — the text chunks
      // we embed are capped well below typical context limits anyway
      // (see RagService._chunkText).
      await engine.loadModel(
        modelPath,
        modelParams: const ModelParams(
          contextSize: 512,
          numberOfThreads: 0,
          numberOfThreadsBatch: 0,
        ),
      );
      _engine = engine;
      _loadedModelPath = modelPath;
    });
  }

  /// Computes an embedding vector for [text]. Returns null if the
  /// underlying llamadart version doesn't expose an embedding API we can
  /// call — probed via dynamic dispatch for the same reason as
  /// llama_service.dart's session hooks: calling a method that may not
  /// exist on this pinned package version must not be a compile-time
  /// gamble.
  Future<List<double>?> embed(String text) async {
    if (_engine == null) return null;
    try {
      final dynamic engine = _engine;
      final result = await engine.embed(text);
      if (result is List) {
        return result.map((v) => (v as num).toDouble()).toList();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> unload() async {
    await _lock.synchronized(_unloadInternal);
  }

  Future<void> _unloadInternal() async {
    await _engine?.dispose();
    _engine = null;
    _loadedModelPath = null;
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
  }
}
