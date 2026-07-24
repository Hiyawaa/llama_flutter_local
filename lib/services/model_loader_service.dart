import 'llama_service.dart';
import 'ram_guard_service.dart';

enum ModelFormat { gguf, liteRtLm, unknown }

/// Result of a load attempt across formats, so callers get a consistent
/// shape regardless of which backend actually handled it.
class ModelLoadResult {
  final bool success;
  final ModelFormat format;
  final String? error;

  const ModelLoadResult(
      {required this.success, required this.format, this.error});
}

/// Feature 2: LiteRT-LM (.litertlm) support alongside .gguf.
///
/// This is an abstraction seam, not a full LiteRT-LM implementation.
/// There is currently no mature, widely-supported pub.dev plugin for
/// running .litertlm models with the breadth of device support llamadart
/// gives us for GGUF — LiteRT-LM support in Flutter today generally means
/// a custom platform channel to Google's native LiteRT runtime per
/// platform. Rather than pretend that's a drop-in dependency, this class:
///
/// 1. Detects format purely from file extension (cheap, no false starts).
/// 2. Routes .gguf to the existing, working LlamaService unchanged.
/// 3. For .litertlm, exposes a clearly-marked `unsupported` result today,
///    with the seam already in place so a real platform-channel-backed
///    runner can be dropped in later without touching ChatProvider or
///    any UI code — they only ever talk to ModelLoaderService.
///
/// This keeps the roadmap honest: Feature 2 ships as "detected and
/// routed, native runtime pending" rather than a fake success path that
/// silently fails at inference time.
class ModelLoaderService {
  final LlamaService _ggufEngine = LlamaService();

  LlamaService get ggufEngine => _ggufEngine;

  ModelFormat detectFormat(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.gguf')) return ModelFormat.gguf;
    if (lower.endsWith('.litertlm')) return ModelFormat.liteRtLm;
    return ModelFormat.unknown;
  }

  Future<ModelLoadResult> load(
    String path, {
    String? mmprojPath,
    int contextSize = 1024,
    int threads = 0,
  }) async {
    final format = detectFormat(path);

    switch (format) {
      case ModelFormat.gguf:
        try {
          // RAM guardrails already live in ChatProvider.loadModel and
          // LlamaService itself; this layer just routes, it doesn't
          // duplicate the check, to avoid two sources of truth on
          // "how much RAM does this need."
          await _ggufEngine.loadModel(
            path,
            mmprojPath: mmprojPath,
            contextSize: contextSize,
            threads: threads,
          );
          return const ModelLoadResult(success: true, format: ModelFormat.gguf);
        } catch (e) {
          return ModelLoadResult(
            success: false,
            format: ModelFormat.gguf,
            error: e.toString(),
          );
        }

      case ModelFormat.liteRtLm:
        // Deliberately not attempted yet — see class doc. Surfacing this
        // clearly to the user (via ModelPickerScreen) is better than a
        // confusing crash or silent no-op deep in inference code.
        return const ModelLoadResult(
          success: false,
          format: ModelFormat.liteRtLm,
          error: '.litertlm models require the LiteRT-LM native runtime, '
              'which isn\'t wired up in this build yet. Use a .gguf model '
              'for now — support is planned via a platform channel.',
        );

      case ModelFormat.unknown:
        return const ModelLoadResult(
          success: false,
          format: ModelFormat.unknown,
          error: 'Unrecognized model file type. Expected .gguf or .litertlm.',
        );
    }
  }

  /// Rough pre-flight check callers (e.g. ModelPickerScreen) can use to
  /// grey out a model in the list before the user even taps it, instead
  /// of letting them attempt a load that RamGuard will just reject.
  Future<bool> looksLoadable(
      String path, int fileSizeBytes, int contextSize) async {
    if (detectFormat(path) != ModelFormat.gguf) return false;
    final estimateMb = RamGuard.estimateModelLoadMb(
      fileSizeBytes: fileSizeBytes,
      contextSize: contextSize,
    );
    return RamGuard.canLoad(estimateMb, failOpen: true);
  }

  void dispose() {
    _ggufEngine.dispose();
  }
}
