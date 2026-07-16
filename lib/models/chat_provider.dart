import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/llama_service.dart';
import '../services/chat_history_service.dart';

export '../services/chat_history_service.dart'
    show SavedConversation, SavedMessage;

enum ChatStatus { idle, loading, generating, error }

class ChatMessage {
  final String role;
  String content;
  final DateTime timestamp;
  bool isStreaming;
  final String? imagePath;

  ChatMessage({
    required this.role,
    required this.content,
    this.isStreaming = false,
    DateTime? timestamp,
    this.imagePath,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatProvider extends ChangeNotifier {
  static const int _defaultMaxTokens = 1024;
  static const int _defaultContextSize = 2048;
  static const int _defaultThreads = 0;
  static const int _streamNotifyMs = 40;
  static const double _defaultTemperature = 0.2;
  static const double _defaultTopP = 0.9;
  static const double _defaultRepeatPenalty = 1.05;

  final LlamaService _llama = LlamaService();
  final ChatHistoryService _history = ChatHistoryService();
  final List<ChatMessage> _messages = [];

  ChatStatus _status = ChatStatus.idle;
  String? _error;
  String? _sessionId;
  DateTime? _sessionStart;

  String _systemPrompt = '';
  double _temperature = _defaultTemperature;
  int _maxTokens = _defaultMaxTokens;
  double _topP = _defaultTopP;
  double _repeatPenalty = _defaultRepeatPenalty;
  int _contextSize = _defaultContextSize;
  int _threads = _defaultThreads;

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

    final trimmed = customPrompt.trim();
    if (trimmed.isEmpty) return mathPrompt;
    return '$trimmed\n\n$mathPrompt';
  }

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  ChatStatus get status => _status;
  String? get error => _error;
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
  ChatHistoryService get historyService => _history;

  // ── Model ──────────────────────────────────────────────────────────────────
  Future<void> loadModel(String path, {String? mmprojPath}) async {
    _status = ChatStatus.loading;
    _error = null;
    notifyListeners();
    try {
      final resolvedMmprojPath = mmprojPath ?? await _findMatchingMmproj(path);
      await _llama.loadModel(
        path,
        mmprojPath: resolvedMmprojPath,
        contextSize: _contextSize,
        threads: _threads,
      );
      _status = ChatStatus.idle;
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
  Future<void> sendMessage(String text, {String? imagePath}) async {
    if (text.trim().isEmpty || isGenerating || !_llama.isReady) return;

    _sessionId ??= DateTime.now().millisecondsSinceEpoch.toString();
    _sessionStart ??= DateTime.now();

    _messages.add(
      ChatMessage(role: 'user', content: text.trim(), imagePath: imagePath),
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

    try {
      await _streamIntoAssistant(
        aiMsg,
        text.trim(),
        history: history,
        imagePath: imagePath,
      );

      if (imagePath == null &&
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
    await for (final token in _llama.chat(
      prompt,
      history: history,
      systemPrompt: _buildEffectiveSystemPrompt(_systemPrompt),
      temperature: _temperature,
      maxTokens: maxTokensOverride ?? _maxTokens,
      topP: _topP,
      repeatPenalty: _repeatPenalty,
      imagePath: imagePath,
    )) {
      aiMsg.content += token;
      if (streamPaintClock.elapsedMilliseconds >= _streamNotifyMs ||
          token.contains('\n')) {
        streamPaintClock.reset();
        notifyListeners();
      }
    }
  }

  bool _looksUnfinished(String content) {
    final text = content.trimRight();
    if (text.length < 600) return false;

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
          // imagePath is not persisted in SavedMessage
        ),
      );
    }
    notifyListeners();
  }

  void clearChat() {
    _messages.clear();
    _sessionId = null;
    _sessionStart = null;
    notifyListeners();
  }

  void updateSettings({
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    double? topP,
    double? repeatPenalty,
    int? contextSize,
    int? threads,
  }) {
    _systemPrompt = systemPrompt ?? _systemPrompt;
    _temperature = temperature ?? _temperature;
    _maxTokens = maxTokens ?? _maxTokens;
    _topP = topP ?? _topP;
    _repeatPenalty = repeatPenalty ?? _repeatPenalty;
    _contextSize = contextSize ?? _contextSize;
    _threads = threads ?? _threads;
    _saveSettings();
    notifyListeners();
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
    _contextSize = p.getInt('contextSize') ?? _defaultContextSize;
    _threads = p.getInt('threads') ?? _defaultThreads;
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
  }

  @override
  void dispose() {
    _llama.dispose();
    super.dispose();
  }
}
