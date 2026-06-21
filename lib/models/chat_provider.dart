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
    this.imagePath,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatProvider extends ChangeNotifier {
  final LlamaService _llama = LlamaService();
  final ChatHistoryService _history = ChatHistoryService();
  final List<ChatMessage> _messages = [];

  ChatStatus _status = ChatStatus.idle;
  String? _error;

  // Current session id (set when first message sent)
  String? _sessionId;
  DateTime? _sessionStart;

  // Settings
  String _systemPrompt = '';
  double _temperature = 0.7;
  int _maxTokens = 2048;
  double _topP = 0.95;
  double _repeatPenalty = 1.1;
  int _contextSize = 2048;
  int _threads = 4;

  ChatProvider() {
    _loadSettings();
  }

  // ── Getters ───────────────────────────────────────────────────────────────
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  ChatStatus get status => _status;
  String? get error => _error;
  LlamaService get llama => _llama;
  bool get isGenerating => _status == ChatStatus.generating;
  bool get isLoadingModel => _status == ChatStatus.loading;
  bool get isVisionCapable => _llama.isVisionCapable;
  String get systemPrompt => _systemPrompt;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  double get topP => _topP;
  double get repeatPenalty => _repeatPenalty;
  int get contextSize => _contextSize;
  int get threads => _threads;
  ChatHistoryService get historyService => _history;

  // ── Model loading ──────────────────────────────────────────────────────────
  Future<void> loadModel(String path) async {
    _status = ChatStatus.loading;
    _error = null;
    notifyListeners();
    try {
      await _llama.loadModel(path,
          contextSize: _contextSize, threads: _threads);
      _status = ChatStatus.idle;
    } catch (e) {
      _status = ChatStatus.error;
      _error = 'Failed to load model: $e';
    }
    notifyListeners();
  }

  Future<void> unloadModel() async {
    await _llama.unload();
    notifyListeners();
  }

  // ── Chat ───────────────────────────────────────────────────────────────────
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || isGenerating || !_llama.isReady) return;

    // Start new session if needed
    if (_sessionId == null) {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionStart = DateTime.now();
    }

    _messages.add(ChatMessage(role: 'user', content: text.trim()));
    _status = ChatStatus.generating;
    _error = null;
    notifyListeners();

    // Snapshot conversation history BEFORE adding the AI placeholder.
    // All previous turns are sent so the model can recall earlier topics.
    final history = _messages
        .sublist(0, _messages.length - 1) // exclude the just-added user msg
        .where((m) => m.content.isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    final aiMsg =
        ChatMessage(role: 'assistant', content: '', isStreaming: true);
    _messages.add(aiMsg);

    try {
      await for (final token in _llama.chat(
        text.trim(),
        history: history,
        systemPrompt: _systemPrompt,
        temperature: _temperature,
        maxTokens: _maxTokens,
        topP: _topP,
        repeatPenalty: _repeatPenalty,
      )) {
        aiMsg.content += token;
        notifyListeners();
      }
    } catch (e) {
      aiMsg.content = 'Error: $e';
      _error = e.toString();
    }

    aiMsg.isStreaming = false;
    _status = ChatStatus.idle;
    notifyListeners();

    // Auto-save after each assistant response
    await _autoSave();
  }

  // ── Image analysis (vision) ─────────────────────────────────────────────────
  /// Send an image + prompt as a chat turn. Behaves like [sendMessage] but
  /// attaches [imagePath] to the user turn so a vision-capable model can see
  /// it. Requires [isVisionCapable] — callers should gate the UI on that
  /// rather than relying on this throwing.
  Future<void> sendImageMessage(String imagePath, String text) async {
    if (text.trim().isEmpty || isGenerating || !_llama.isReady) return;
    if (!isVisionCapable) {
      _error = 'Loaded model has no vision support';
      notifyListeners();
      return;
    }

    if (_sessionId == null) {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionStart = DateTime.now();
    }

    _messages.add(ChatMessage(
      role: 'user',
      content: text.trim(),
      imagePath: imagePath,
    ));
    _status = ChatStatus.generating;
    _error = null;
    notifyListeners();

    final history = _messages
        .sublist(0, _messages.length - 1)
        .where((m) => m.content.isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    final aiMsg =
        ChatMessage(role: 'assistant', content: '', isStreaming: true);
    _messages.add(aiMsg);

    try {
      await for (final token in _llama.chatWithImage(
        imagePath,
        text.trim(),
        history: history,
        systemPrompt: _systemPrompt,
      )) {
        aiMsg.content += token;
        notifyListeners();
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

  // ── Stop generation ────────────────────────────────────────────────────────
  void stopGeneration() {
    _llama.stop();
    if (_messages.isNotEmpty && _messages.last.isStreaming) {
      _messages.last.isStreaming = false;
    }
    _status = ChatStatus.idle;
    notifyListeners();
  }

  // ── History ────────────────────────────────────────────────────────────────
  Future<void> _autoSave() async {
    if (_messages.isEmpty || _sessionId == null) return;

    final userMessages = _messages.where((m) => m.role == 'user').toList();
    if (userMessages.isEmpty) return;

    final title = userMessages.first.content.length > 60
        ? '${userMessages.first.content.substring(0, 60)}…'
        : userMessages.first.content;

    final modelName =
        _llama.loadedPath != null ? p.basename(_llama.loadedPath!) : null;

    final conv = SavedConversation(
      id: _sessionId!,
      title: title,
      createdAt: _sessionStart!,
      modelName: modelName,
      messages: _messages
          .map((m) => SavedMessage(
                role: m.role,
                content: m.content,
                timestamp: m.timestamp,
                imagePath: m.imagePath,
              ))
          .toList(),
    );
    await _history.save(conv);
  }

  /// Load a saved conversation back into the chat
  void loadConversation(SavedConversation conv) {
    _messages.clear();
    _sessionId = conv.id;
    _sessionStart = conv.createdAt;
    for (final m in conv.messages) {
      _messages.add(ChatMessage(
        role: m.role,
        content: m.content,
        timestamp: m.timestamp,
        imagePath: m.imagePath,
      ));
    }
    notifyListeners();
  }

  void clearChat() {
    _messages.clear();
    _sessionId = null;
    _sessionStart = null;
    notifyListeners();
  }

  // ── Settings ───────────────────────────────────────────────────────────────
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
    _temperature = p.getDouble('temperature') ?? 0.7;
    _maxTokens = p.getInt('maxTokens') ?? 2048;
    _topP = p.getDouble('topP') ?? 0.95;
    _repeatPenalty = p.getDouble('repeatPenalty') ?? 1.1;
    _contextSize = p.getInt('contextSize') ?? 2048;
    _threads = p.getInt('threads') ?? 4;
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
