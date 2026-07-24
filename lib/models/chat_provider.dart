import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/llama_service.dart';
import '../services/chat_history_service.dart';
import '../services/ram_guard_service.dart';
import '../services/tool_service.dart';
import '../services/kv_cache_service.dart';
import '../services/rag_service.dart';

export '../services/chat_history_service.dart'
    show SavedConversation, SavedMessage;

enum ChatStatus { idle, loading, generating, error }

class ChatMessage {
  final String role;
  String content;
  final DateTime timestamp;
  bool isStreaming;
  final String? imagePath;
  final List<String> imagePaths;
  // Populated only for assistant messages once streaming finishes.
  GenerationMetrics? metrics;
  // Populated when the model emitted a tool call this turn (Feature 7).
  ToolCallResult? toolCall;
  // True if this turn had to skip the model's chat template and fall
  // back to a hand-built raw prompt — a strong signal that any oddness
  // in this response (run-on text, missing spaces, repetition) may be a
  // model/template compatibility issue rather than the model just being
  // weak. Surfaced in the UI rather than only logged, so it's actually
  // discoverable when debugging a specific model's output quality.
  bool usedFallback;

  ChatMessage({
    required this.role,
    required this.content,
    this.isStreaming = false,
    DateTime? timestamp,
    this.imagePath,
    List<String>? imagePaths,
    this.metrics,
    this.toolCall,
    this.usedFallback = false,
  })  : imagePaths = imagePaths ??
            (imagePath != null && imagePath.isNotEmpty ? [imagePath] : const []),
        timestamp = timestamp ?? DateTime.now();
}

/// Tokens/sec + timing for a single assistant turn (Feature 5).
class GenerationMetrics {
  final int tokenCount;
  final Duration elapsed;

  GenerationMetrics({required this.tokenCount, required this.elapsed});

  double get tokensPerSecond =>
      elapsed.inMilliseconds <= 0 ? 0 : tokenCount / (elapsed.inMilliseconds / 1000);

  String get label =>
      '${tokensPerSecond.toStringAsFixed(1)} tok/s · ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

class ChatProvider extends ChangeNotifier {
  // Hard RAM-safety defaults for 4GB-class devices. Context size in
  // particular directly multiplies KV-cache memory, so 1024 is the
  // ceiling unless RamGuard confirms there's real headroom (see
  // updateSettings below).
  static const int _defaultMaxTokens = 1024;
  static const int _defaultContextSize = 1024;
  static const int _hardContextCeilingLowRam = 1024;
  static const int _hardContextCeilingUnlocked = 4096;
  static const int _defaultThreads = 0;
  static const int _streamNotifyMs = 40;
  static const double _defaultTemperature = 0.2;
  static const double _defaultTopP = 0.9;
  static const double _defaultRepeatPenalty = 1.05;

  final LlamaService _llama = LlamaService();
  final ChatHistoryService _history = ChatHistoryService();
  final ToolService _tools = ToolService();
  final KvCacheService _kvCache = KvCacheService();
  final RagService _rag = RagService();
  final List<ChatMessage> _messages = [];

  ChatStatus _status = ChatStatus.idle;
  String? _error;
  String? _sessionId;
  DateTime? _sessionStart;
  String? _ramWarning;

  String _systemPrompt = '';
  double _temperature = _defaultTemperature;
  int _maxTokens = _defaultMaxTokens;
  double _topP = _defaultTopP;
  double _repeatPenalty = _defaultRepeatPenalty;
  int _contextSize = _defaultContextSize;
  int _threads = _defaultThreads;
  bool _jsonMode = false;
  bool _thinkingMode = false;
  bool _toolsEnabled = false;
  bool _ragEnabled = false;
  String? _embeddingModelPath;
  bool _ragBusy = false;

  ChatProvider() {
    _loadSettings();
  }

  String _buildEffectiveSystemPrompt(String customPrompt) {
    const mathPrompt = r'''
When answering mathematics, use clean Markdown plus LaTeX:
- Put inline math in $...$ and important equations in $$...$$.
- For matrices, systems, cases, and integration-by-parts tables, use LaTeX environments such as \begin{bmatrix}...\end{bmatrix}, \begin{pmatrix}...\end{pmatrix}, \begin{cases}...\end{cases}, or \begin{array}{c|c}...\end{array} inside display math.
- For integration by parts, define u and dv clearly, show du and v, then verify the final expression by differentiation when practical.
- Avoid leaving half-finished LaTeX delimiters or unmatched braces.''';

    const jsonPrompt = r'''
Respond with STRICT JSON only. No prose, no Markdown code fences, no
commentary before or after. The entire response must be a single valid
JSON value.''';

    final toolPrompt = _toolsEnabled
        ? '''
You have access to tools. To use one, respond with ONLY a JSON object of
the exact form {"tool_call": {"name": "<tool>", "arguments": {...}}} and
nothing else. Available tools:
${_tools.describeTools()}
If no tool is needed, answer normally.'''
        : '';

    final parts = <String>[];
    final trimmed = customPrompt.trim();
    if (trimmed.isNotEmpty) parts.add(trimmed);
    parts.add(mathPrompt);
    if (_jsonMode) parts.add(jsonPrompt);
    if (_toolsEnabled) parts.add(toolPrompt);
    return parts.join('\n\n');
  }

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  ChatStatus get status => _status;
  String? get error => _error;
  String? get ramWarning => _ramWarning;

  void dismissRamWarning() {
    _ramWarning = null;
    notifyListeners();
  }
  LlamaService get llama => _llama;
  bool get isGenerating => _status == ChatStatus.generating;
  bool get isLoadingModel => _status == ChatStatus.loading;
  String get systemPrompt => _systemPrompt;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  double get topP => _topP;
  double get repeatPenalty => _repeatPenalty;
  int get contextSize => _contextSize;
  int get threads => _threads;
  bool get jsonMode => _jsonMode;
  bool get thinkingMode => _thinkingMode;
  bool get toolsEnabled => _toolsEnabled;
  bool get ragEnabled => _ragEnabled;
  bool get ragBusy => _ragBusy;
  String? get embeddingModelPath => _embeddingModelPath;
  ChatHistoryService get historyService => _history;
  ToolService get toolService => _tools;
  KvCacheService get kvCacheService => _kvCache;
  RagService get ragService => _rag;

  // ── Model ──────────────────────────────────────────────────────────────────
  Future<void> loadModel(String path, {String? mmprojPath}) async {
    _status = ChatStatus.loading;
    _error = null;
    _ramWarning = null;
    notifyListeners();
    try {
      // RAM guardrail: estimate footprint before committing to a load.
      // On a 4GB device an unchecked load of a model that's too big for
      // available headroom risks the whole process getting OOM-killed
      // with zero warning to the user.
      final fileSize = await File(path).length();
      final estimateMb = RamGuard.estimateModelLoadMb(
        fileSizeBytes: fileSize,
        contextSize: _contextSize,
      );
      await RamGuard.ensureCanLoad(
        estimateMb,
        operation: 'load this model',
      );

      final resolvedMmprojPath = mmprojPath ?? await _findMatchingMmproj(path);

      // mmproj (vision projector) adds substantial extra resident memory
      // on top of the base model. Re-check headroom specifically before
      // loading it, and skip vision support entirely (falling back to a
      // text-only load) rather than risk OOM — a chat that works beats a
      // vision feature that crashes the app.
      String? safeMmprojPath = resolvedMmprojPath;
      if (resolvedMmprojPath != null) {
        try {
          final mmprojSize = await File(resolvedMmprojPath).length();
          final mmprojEstimateMb =
              (mmprojSize / (1024 * 1024)).ceil() + 200; // + working buffer
          final ok = await RamGuard.canLoad(mmprojEstimateMb);
          if (!ok) {
            safeMmprojPath = null;
            _ramWarning =
                'Not enough free RAM for the vision projector — loaded '
                'text-only. Close other apps and reload to enable images.';
          }
        } catch (_) {
          safeMmprojPath = null;
        }
      }

      await _llama.loadModel(
        path,
        mmprojPath: safeMmprojPath,
        contextSize: _contextSize,
        threads: _threads,
      );
      _status = ChatStatus.idle;

      // Feature 1 (KV-Cache persistence): if we're resuming a specific
      // conversation (loadConversation sets _sessionId before calling
      // loadModel in that flow), try a fast session restore now rather
      // than waiting for the first message — this is the whole point of
      // KV-cache persistence, avoiding a slow prompt-reprocessing pass.
      if (_sessionId != null) {
        final outcome = await _kvCache.restoreSession(_llama, _sessionId!);
        if (outcome == KvRestoreOutcome.needsReplay && _messages.isNotEmpty) {
          // No native session available — fall back to replaying the
          // conversation's existing messages as history on the next
          // sendMessage call (ChatProvider already does this via
          // _messages.sublist(...) in sendMessage, so no extra action is
          // needed here beyond leaving _messages populated).
        }
      }
    } on RamGuardException catch (e) {
      _status = ChatStatus.error;
      _error = e.message;
    } catch (e) {
      _status = ChatStatus.error;
      _error = 'Failed to load model: $e';
    }
    notifyListeners();
  }

  Future<String?> _findMatchingMmproj(String modelPath) async {
    final modelFile = File(modelPath);
    final dir = modelFile.parent;
    if (!await dir.exists()) return null;

    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.gguf'))
        .cast<File>()
        .toList();
    final mmprojFiles = files
        .where((f) => p.basename(f.path).toLowerCase().contains('mmproj'))
        .toList();
    if (mmprojFiles.isEmpty) return null;
    if (mmprojFiles.length == 1) return mmprojFiles.first.path;

    final modelName = p.basenameWithoutExtension(modelPath).toLowerCase();
    final scored = mmprojFiles.map((file) {
      final name = p.basenameWithoutExtension(file.path).toLowerCase();
      final sharedTokens = modelName
          .split(RegExp(r'[^a-z0-9]+'))
          .where((token) => token.length > 2 && name.contains(token))
          .length;
      return MapEntry(file, sharedTokens);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return scored.first.key.path;
  }

  Future<void> unloadModel() async {
    await _llama.unload();
    notifyListeners();
  }

  // ── Chat ───────────────────────────────────────────────────────────────────
  Future<void> sendMessage(String text, {List<String>? imagePaths}) async {
    if (text.trim().isEmpty || isGenerating || !_llama.isReady) return;

    _sessionId ??= DateTime.now().millisecondsSinceEpoch.toString();
    _sessionStart ??= DateTime.now();

    final images = imagePaths ?? const <String>[];

    _messages.add(
      ChatMessage(
        role: 'user',
        content: text.trim(),
        imagePaths: images,
      ),
    );
    _status = ChatStatus.generating;
    _error = null;
    notifyListeners();

    final history = _messages
        .sublist(0, _messages.length - 1)
        .where((m) => m.content.isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    final aiMsg = ChatMessage(
      role: 'assistant',
      content: '',
      isStreaming: true,
    );
    _messages.add(aiMsg);

    // Multi-turn vision: llamadart's current chat() takes a single image
    // path. Until multi-image support lands upstream, we pass the first
    // image as the "active" one and fold any additional image paths into
    // the prompt text as explicit references so the model at least knows
    // they exist. This is a deliberate, documented limitation rather than
    // a silent drop.
    // Feature 3 (RAG): if enabled, this swaps the chat model out for the
    // embedding model, searches, then swaps the chat model back in
    // before continuing — two full model loads on top of the normal
    // generation. That's a real, user-visible latency cost (several
    // seconds to tens of seconds depending on model size), but it's the
    // honest price of the "never two models resident at once" rule this
    // app enforces for 4GB devices. Skipped entirely for image turns,
    // where mmproj is already the memory-heavy component in play.
    var promptText = images.length > 1
        ? '${text.trim()}\n\n[${images.length - 1} additional image(s) attached — '
            'only the first image is visible to you this turn.]'
        : text.trim();

    if (_ragEnabled && images.isEmpty) {
      final ragContext = await _ragContextFor(text.trim());
      if (ragContext.isNotEmpty) {
        promptText = '$ragContext\n\nQuestion: $promptText';
      }
    }

    final primaryImage = images.isNotEmpty ? images.first : null;

    try {
      await _streamIntoAssistant(
        aiMsg,
        promptText,
        history: history,
        imagePath: primaryImage,
      );

      // Feature 7: if the model emitted a tool call instead of a normal
      // answer, execute it and feed the result back as a follow-up turn
      // rather than showing raw JSON to the user.
      if (_toolsEnabled && images.isEmpty) {
        final call = _tools.tryParseToolCall(aiMsg.content);
        if (call != null) {
          aiMsg.toolCall = call;
          notifyListeners();
          final result = await _tools.execute(call);
          aiMsg.toolCall = call.copyWithResult(result);
          notifyListeners();

          final followUpHistory = _messages
              .where((m) => m.content.isNotEmpty)
              .map((m) => {'role': m.role, 'content': m.content})
              .toList();
          final followUp = ChatMessage(role: 'assistant', content: '', isStreaming: true);
          _messages.add(followUp);
          notifyListeners();
          await _streamIntoAssistant(
            followUp,
            'Tool "${call.name}" returned: $result\n\n'
            'Now answer the original question using this result.',
            history: followUpHistory,
          );
          followUp.isStreaming = false;
        }
      }

      if (primaryImage == null &&
          !_llama.stopRequested &&
          _looksUnfinished(aiMsg.content)) {
        final continuationHistory = _messages
            .where((m) => m.content.isNotEmpty)
            .map((m) => {'role': m.role, 'content': m.content})
            .toList();
        aiMsg.content = '${aiMsg.content.trimRight()}\n\n';
        notifyListeners();
        await _streamIntoAssistant(
          aiMsg,
          'Continue exactly from where you stopped. Do not restart or repeat '
          'earlier steps. Finish the answer.',
          history: continuationHistory,
          maxTokensOverride: (_maxTokens / 2).ceil().clamp(256, 1024),
        );
      }
    } catch (e) {
      aiMsg.content = 'Error: $e';
      _error = e.toString();
    }

    aiMsg.isStreaming = false;
    _status = ChatStatus.idle;
    notifyListeners();
    await _autoSave();
  }

  Future<void> _streamIntoAssistant(
    ChatMessage aiMsg,
    String prompt, {
    required List<Map<String, String>> history,
    String? imagePath,
    int? maxTokensOverride,
  }) async {
    final streamPaintClock = Stopwatch()..start();
    final turnClock = Stopwatch()..start();
    int tokenCount = 0;

    await for (final token in _llama.chat(
      prompt,
      history: history,
      systemPrompt: _buildEffectiveSystemPrompt(_systemPrompt),
      temperature: _temperature,
      // Thinking mode needs headroom for the reasoning trace on top of
      // the actual answer — without this, a reasoning model can burn its
      // entire token budget "thinking" and get cut off before it ever
      // writes a visible answer. Doubled, capped so it can't blow past
      // a sane ceiling on a RAM-constrained device.
      maxTokens: maxTokensOverride ??
          (_thinkingMode ? (_maxTokens * 2).clamp(256, 4096) : _maxTokens),
      topP: _topP,
      repeatPenalty: _repeatPenalty,
      imagePath: imagePath,
      enableThinking: _thinkingMode,
    )) {
      aiMsg.content += token;
      tokenCount++;
      if (streamPaintClock.elapsedMilliseconds >= _streamNotifyMs ||
          token.contains('\n')) {
        streamPaintClock.reset();
        notifyListeners();
      }
    }

    turnClock.stop();
    aiMsg.metrics = GenerationMetrics(
      tokenCount: tokenCount,
      elapsed: turnClock.elapsed,
    );
    if (_llama.lastTurnUsedFallback) {
      aiMsg.usedFallback = true;
    }
  }

  bool _looksUnfinished(String content) {
    final text = content.trimRight();
    if (text.length < 600) return false;
    // JSON-mode / tool-call responses are structured, single-shot outputs —
    // the "unfinished prose" heuristic below doesn't apply and could
    // trigger a spurious continuation that corrupts otherwise-valid JSON.
    if (_jsonMode) return false;

    if (RegExp(r'```').allMatches(text).length.isOdd) return true;
    if (RegExp(r'(?<!\\)\$').allMatches(text).length.isOdd) return true;

    final lastLine = text.split('\n').last.trim();
    if (lastLine.isEmpty) return false;
    if (RegExp(r'[.!?。！？)\]}]$').hasMatch(lastLine)) return false;
    if (RegExp(r'[:;,=+\-*/\\]$').hasMatch(lastLine)) return true;

    return RegExp(
      r'\b(?:from|then|where|because|therefore|so|and|or|with|by|to|the|'
      r'a|an|of|in|is|are|be|we|get|got|solve|substitute)$',
      caseSensitive: false,
    ).hasMatch(lastLine);
  }

  void stopGeneration() {
    _llama.stop();
    if (_messages.isNotEmpty && _messages.last.isStreaming) {
      _messages.last.isStreaming = false;
    }
    _status = ChatStatus.idle;
    notifyListeners();
  }

  // ── RAG (Feature 3) ──────────────────────────────────────────────────────
  //
  // The embedder and the chat model must never be resident at once on a
  // 4GB device (see embedding_service.dart's class doc). Since only
  // ChatProvider holds a reference to both LlamaService (chat) and
  // EmbeddingService (embed), ChatProvider is the one place that can
  // safely orchestrate the handoff — that's why this logic lives here
  // rather than inside RagService itself.

  void setEmbeddingModelPath(String path) {
    _embeddingModelPath = path;
    notifyListeners();
  }

  Future<void> setRagEnabled(bool enabled) async {
    _ragEnabled = enabled;
    notifyListeners();
  }

  /// Indexes [text] under [docId]/[sourceName]. Temporarily unloads the
  /// chat model, loads the embedding model, indexes, then restores the
  /// chat model to where it was. This is intentionally slow (two model
  /// loads) rather than fast-and-risky (both models resident) — on a 4GB
  /// device that tradeoff isn't optional.
  Future<int> indexRagDocument({
    required String docId,
    required String sourceName,
    required String text,
  }) async {
    if (_embeddingModelPath == null) {
      throw StateError('No embedding model selected. Set one in Settings first.');
    }
    _ragBusy = true;
    notifyListeners();

    final previousChatPath = _llama.loadedPath;
    final previousMmproj = _llama.loadedMmprojPath;
    try {
      await _llama.unload();
      await _rag.embeddingService.load(_embeddingModelPath!);
      final count = await _rag.indexDocument(docId: docId, sourceName: sourceName, text: text);
      return count;
    } finally {
      await _rag.embeddingService.unload();
      if (previousChatPath != null) {
        await loadModel(previousChatPath, mmprojPath: previousMmproj);
      }
      _ragBusy = false;
      notifyListeners();
    }
  }

  /// Runs a RAG search and returns a context block to prepend to the next
  /// prompt. Same unload/reload dance as indexing — called from
  /// sendMessage only when [_ragEnabled] is true.
  Future<String> _ragContextFor(String query) async {
    if (_embeddingModelPath == null) return '';
    final previousChatPath = _llama.loadedPath;
    final previousMmproj = _llama.loadedMmprojPath;
    try {
      await _llama.unload();
      await _rag.embeddingService.load(_embeddingModelPath!);
      final results = await _rag.search(query);
      return _rag.buildContextBlock(results);
    } catch (_) {
      return '';
    } finally {
      await _rag.embeddingService.unload();
      if (previousChatPath != null) {
        await loadModel(previousChatPath, mmprojPath: previousMmproj);
      }
    }
  }

  Future<void> _autoSave() async {
    if (_messages.isEmpty || _sessionId == null) return;
    final userMsgs = _messages.where((m) => m.role == 'user').toList();
    if (userMsgs.isEmpty) return;

    final title = userMsgs.first.content.length > 60
        ? '${userMsgs.first.content.substring(0, 60)}…'
        : userMsgs.first.content;

    await _history.save(
      SavedConversation(
        id: _sessionId!,
        title: title,
        createdAt: _sessionStart!,
        modelName:
            _llama.loadedPath != null ? p.basename(_llama.loadedPath!) : null,
        messages: _messages
            .map(
              (m) => SavedMessage(
                role: m.role,
                content: m.content,
                timestamp: m.timestamp,
              ),
            )
            .toList(),
      ),
    );

    // Feature 1: best-effort KV-cache save. This is deliberately
    // fire-and-forget-ish (awaited, but failures are swallowed) — a
    // failed session save should never surface as a chat error to the
    // user, since the conversation-text save above already succeeded and
    // is the thing that actually guarantees no data loss. The session
    // cache is a speed optimization on resume, not a correctness
    // requirement.
    try {
      await _kvCache.saveSession(_llama, _sessionId!);
    } catch (_) {}
  }

  void loadConversation(SavedConversation conv) {
    _messages.clear();
    _sessionId = conv.id;
    _sessionStart = conv.createdAt;
    for (final m in conv.messages) {
      _messages.add(
        ChatMessage(
          role: m.role,
          content: m.content,
          timestamp: m.timestamp,
          // imagePaths are not persisted in SavedMessage
        ),
      );
    }
    notifyListeners();

    // Feature 1: if a model is already loaded, opportunistically try a
    // KV-cache restore for this conversation right away rather than
    // waiting for the user's next message. If nothing was ever saved for
    // this session (or the engine doesn't support sessions), this is a
    // silent no-op — sendMessage's normal history replay via _messages
    // is still the correctness fallback either way.
    if (_llama.isReady) {
      _kvCache.restoreSession(_llama, conv.id).catchError(
        (_) => KvRestoreOutcome.failed,
      );
    }
  }

  void clearChat() {
    _messages.clear();
    _sessionId = null;
    _sessionStart = null;
    notifyListeners();
  }

  /// Updates settings. [contextSize] is clamped according to the current
  /// RAM tier: on low-RAM devices (the default assumption) it's hard-capped
  /// at 1024. Callers wanting more must have already confirmed via
  /// [canUnlockLargerContext] that the device has real headroom.
  Future<void> updateSettings({
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    double? topP,
    double? repeatPenalty,
    int? contextSize,
    int? threads,
    bool? jsonMode,
    bool? thinkingMode,
    bool? toolsEnabled,
  }) async {
    _systemPrompt = systemPrompt ?? _systemPrompt;
    _temperature = temperature ?? _temperature;
    _maxTokens = maxTokens ?? _maxTokens;
    _topP = topP ?? _topP;
    _repeatPenalty = repeatPenalty ?? _repeatPenalty;
    _threads = threads ?? _threads;
    _jsonMode = jsonMode ?? _jsonMode;
    _thinkingMode = thinkingMode ?? _thinkingMode;
    _toolsEnabled = toolsEnabled ?? _toolsEnabled;

    if (contextSize != null) {
      _contextSize = await _clampContextSize(contextSize);
    }

    _saveSettings();
    notifyListeners();
  }

  /// Returns true if the device currently has enough free RAM to justify
  /// unlocking context sizes above the low-RAM ceiling. Settings UI should
  /// call this to decide whether to show the "Advanced" section at all.
  Future<bool> canUnlockLargerContext() async {
    final isLowRam = await RamGuard.isLowRamDevice();
    if (!isLowRam) return true;
    // Even on a device that reports >6GB total, still require real
    // available headroom right now before unlocking.
    return RamGuard.canLoad(600, failOpen: false);
  }

  Future<int> _clampContextSize(int requested) async {
    final unlocked = await canUnlockLargerContext();
    final ceiling =
        unlocked ? _hardContextCeilingUnlocked : _hardContextCeilingLowRam;
    return requested.clamp(256, ceiling);
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    _systemPrompt = p.getString('systemPrompt') ?? '';
    final savedTemperature = p.getDouble('temperature');
    final savedTopP = p.getDouble('topP');
    final savedRepeatPenalty = p.getDouble('repeatPenalty');

    _temperature = savedTemperature == null || savedTemperature == 0.7
        ? _defaultTemperature
        : savedTemperature;
    _maxTokens = p.getInt('maxTokens') ?? _defaultMaxTokens;
    _topP = savedTopP == null || savedTopP == 0.95 ? _defaultTopP : savedTopP;
    _repeatPenalty = savedRepeatPenalty == null || savedRepeatPenalty == 1.1
        ? _defaultRepeatPenalty
        : savedRepeatPenalty;

    // Re-validate the persisted context size against the current device's
    // RAM tier every launch — a value saved on a beefier test device (or
    // before this guardrail existed) must not silently bypass the cap.
    final savedContext = p.getInt('contextSize') ?? _defaultContextSize;
    _contextSize = await _clampContextSize(savedContext);

    _threads = p.getInt('threads') ?? _defaultThreads;
    _jsonMode = p.getBool('jsonMode') ?? false;
    _thinkingMode = p.getBool('thinkingMode') ?? false;
    _toolsEnabled = p.getBool('toolsEnabled') ?? false;
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('systemPrompt', _systemPrompt);
    await p.setDouble('temperature', _temperature);
    await p.setInt('maxTokens', _maxTokens);
    await p.setDouble('topP', _topP);
    await p.setDouble('repeatPenalty', _repeatPenalty);
    await p.setInt('contextSize', _contextSize);
    await p.setInt('threads', _threads);
    await p.setBool('jsonMode', _jsonMode);
    await p.setBool('thinkingMode', _thinkingMode);
    await p.setBool('toolsEnabled', _toolsEnabled);
  }

  @override
  void dispose() {
    _llama.dispose();
    super.dispose();
  }
}