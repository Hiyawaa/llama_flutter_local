import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:llamadart/llamadart.dart';

enum ModelStatus { unloaded, loading, ready, error }

class LlamaService {
  ModelStatus _status = ModelStatus.unloaded;
  String? _loadedPath;
  String? _mmprojPath;
  String? _errorMessage;
  LlamaEngine? _engine;
  bool _stopRequested = false;

  ModelStatus get status => _status;
  String? get loadedPath => _loadedPath;
  String? get mmprojPath => _mmprojPath;
  String? get errorMessage => _errorMessage;
  bool get isReady => _status == ModelStatus.ready;

  /// True when a multimodal projector was found and loaded alongside the
  /// main model, meaning this model can analyse images as well as chat.
  bool get isVisionCapable => _mmprojPath != null;

  /// Look for a vision projector ("mmproj") file living next to the main
  /// model file. GGUF vision models are almost always distributed as a pair:
  /// the main weights + a small mmproj-*.gguf file in the same folder.
  /// Returns the projector path if one is found, otherwise null.
  Future<String?> _findMmprojNextTo(String modelPath) async {
    try {
      final dir = Directory(p.dirname(modelPath));
      if (!await dir.exists()) return null;
      await for (final entry in dir.list(recursive: false)) {
        if (entry is! File) continue;
        final name = p.basename(entry.path).toLowerCase();
        if (name.contains('mmproj') && name.endsWith('.gguf')) {
          return entry.path;
        }
      }
    } catch (_) {
      // Inaccessible directory — treat as "no projector found" rather than
      // failing the whole model load.
    }
    return null;
  }

  Future<void> loadModel(
    String path, {
    int contextSize = 2048,
    int threads = 4,
    String? mmprojPath,
  }) async {
    await unload();
    _status = ModelStatus.loading;
    _errorMessage = null;
    try {
      _engine = LlamaEngine(LlamaBackend());
      await _engine!.loadModel(path);
      _loadedPath = path;

      // Use an explicitly provided mmproj if given, otherwise auto-detect
      // one sitting next to the model file.
      final projector = mmprojPath ?? await _findMmprojNextTo(path);
      if (projector != null) {
        try {
          await _engine!.loadMultimodalProjector(projector);
          _mmprojPath = projector;
        } catch (_) {
          // Projector failed to load (corrupt/incompatible) — fall back to
          // text-only rather than failing the whole model load.
          _mmprojPath = null;
        }
      } else {
        _mmprojPath = null;
      }

      _status = ModelStatus.ready;
    } catch (e) {
      _status = ModelStatus.error;
      _errorMessage = e.toString();
      _engine = null;
      rethrow;
    }
  }

  /// Manually attach (or replace) the vision projector for the currently
  /// loaded model, for cases where auto-detection doesn't find it (e.g. the
  /// mmproj file lives in a different folder).
  Future<void> attachMmproj(String mmprojPath) async {
    if (_engine == null || !isReady) {
      throw StateError('Load a model before attaching a vision projector');
    }
    await _engine!.loadMultimodalProjector(mmprojPath);
    _mmprojPath = mmprojPath;
  }

  // ── Stop mid-generation ──────────────────────────────────────────────────
  void stop() => _stopRequested = true;

  /// [history] is the ordered list of previous turns (role + content) so the
  /// model has full context and can reference earlier topics in the conversation.
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

    // Build the full message list: system -> history -> current user turn.
    // Passing the whole conversation gives the model memory of earlier topics.
    final messages = <LlamaChatMessage>[];

    if (systemPrompt.isNotEmpty) {
      messages.add(LlamaChatMessage(role: 'system', content: systemPrompt));
    }

    for (final h in history) {
      final role = h['role'] ?? 'user';
      final content = h['content'] ?? '';
      if (content.isNotEmpty) {
        messages.add(LlamaChatMessage(role: role, content: content));
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
      // Fallback: build a plain-text prompt that includes history
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

  /// Analyse an image with a text prompt, optionally continuing a prior
  /// text-only conversation so the model can reference earlier turns.
  /// Requires [isVisionCapable] — throws otherwise.
  Stream<String> chatWithImage(
    String imagePath,
    String userMessage, {
    List<Map<String, String>> history = const [],
    String systemPrompt = '',
    double temperature = 0.3,
    int maxTokens = 1024,
  }) async* {
    if (_engine == null || !isReady) throw StateError('Model not loaded');
    if (!isVisionCapable) {
      throw StateError('This model has no vision projector loaded');
    }
    _stopRequested = false;

    final messages = <LlamaChatMessage>[];

    if (systemPrompt.isNotEmpty) {
      messages.add(LlamaChatMessage(role: 'system', content: systemPrompt));
    }

    for (final h in history) {
      final role = h['role'] ?? 'user';
      final content = h['content'] ?? '';
      if (content.isNotEmpty) {
        messages.add(LlamaChatMessage(role: role, content: content));
      }
    }

    // The image is attached to the current user turn only.
    messages.add(LlamaChatMessage.withContent(
      role: LlamaChatRole.user,
      content: [
        LlamaImageContent(path: imagePath),
        LlamaTextContent(userMessage),
      ],
    ));

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
    _status = ModelStatus.unloaded;
    _loadedPath = null;
    _mmprojPath = null;
    _errorMessage = null;
  }

  void dispose() {
    _engine?.dispose();
    _engine = null;
  }
}
