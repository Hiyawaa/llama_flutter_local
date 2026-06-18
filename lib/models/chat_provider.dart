import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:llama_flutter_local/services/llama_service.dart';

enum ChatStatus { idle, loading, generating, error }

class ChatMessage {
  final String role;
  String content;
  final DateTime timestamp;
  bool isStreaming;

  ChatMessage({
    required this.role,
    required this.content,
    this.isStreaming = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatProvider extends ChangeNotifier {
  final LlamaService _llama = LlamaService();
  final List<ChatMessage> _messages = [];

  ChatStatus _status = ChatStatus.idle;
  String? _error;

  // Settings
  String _systemPrompt = '';
  double _temperature  = 0.7;
  int    _maxTokens    = 2048;
  double _topP         = 0.95;
  double _repeatPenalty= 1.1;
  int    _contextSize  = 2048;
  int    _threads      = 4;

  ChatProvider() {
    _loadSettings();
  }

  // ── Getters ──────────────────────────────────────────────────────────────
  List<ChatMessage> get messages       => List.unmodifiable(_messages);
  ChatStatus        get status         => _status;
  String?           get error          => _error;
  LlamaService      get llama          => _llama;
  bool              get isGenerating   => _status == ChatStatus.generating;
  bool              get isLoadingModel => _status == ChatStatus.loading;
  String            get systemPrompt   => _systemPrompt;
  double            get temperature    => _temperature;
  int               get maxTokens      => _maxTokens;
  double            get topP           => _topP;
  double            get repeatPenalty  => _repeatPenalty;
  int               get contextSize    => _contextSize;
  int               get threads        => _threads;

  // ── Model loading ─────────────────────────────────────────────────────────
  Future<void> loadModel(String path) async {
    _status = ChatStatus.loading;
    _error = null;
    notifyListeners();

    try {
      await _llama.loadModel(
        path,
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

  Future<void> unloadModel() async {
    await _llama.unload();
    notifyListeners();
  }

  // ── Chat ──────────────────────────────────────────────────────────────────
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || isGenerating || !_llama.isReady) return;

    _messages.add(ChatMessage(role: 'user', content: text.trim()));
    _status = ChatStatus.generating;
    _error = null;
    notifyListeners();

    final aiMsg = ChatMessage(
      role: 'assistant',
      content: '',
      isStreaming: true,
    );
    _messages.add(aiMsg);

    try {
      await for (final token in _llama.chat(
        text.trim(),
        systemPrompt:  _systemPrompt,
        temperature:   _temperature,
        maxTokens:     _maxTokens,
        topP:          _topP,
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
  }

  void clearChat() {
    _messages.clear();
    notifyListeners();
  }

  // ── Settings ──────────────────────────────────────────────────────────────
  void updateSettings({
    String?  systemPrompt,
    double?  temperature,
    int?     maxTokens,
    double?  topP,
    double?  repeatPenalty,
    int?     contextSize,
    int?     threads,
  }) {
    _systemPrompt  = systemPrompt  ?? _systemPrompt;
    _temperature   = temperature   ?? _temperature;
    _maxTokens     = maxTokens     ?? _maxTokens;
    _topP          = topP          ?? _topP;
    _repeatPenalty = repeatPenalty ?? _repeatPenalty;
    _contextSize   = contextSize   ?? _contextSize;
    _threads       = threads       ?? _threads;
    _saveSettings();
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    _systemPrompt  = p.getString('systemPrompt') ?? '';
    _temperature   = p.getDouble('temperature')  ?? 0.7;
    _maxTokens     = p.getInt   ('maxTokens')    ?? 2048;
    _topP          = p.getDouble('topP')         ?? 0.95;
    _repeatPenalty = p.getDouble('repeatPenalty')?? 1.1;
    _contextSize   = p.getInt   ('contextSize')  ?? 2048;
    _threads       = p.getInt   ('threads')      ?? 4;
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('systemPrompt',  _systemPrompt);
    await p.setDouble('temperature',   _temperature);
    await p.setInt   ('maxTokens',     _maxTokens);
    await p.setDouble('topP',          _topP);
    await p.setDouble('repeatPenalty', _repeatPenalty);
    await p.setInt   ('contextSize',   _contextSize);
    await p.setInt   ('threads',       _threads);
  }

  @override
  void dispose() {
    _llama.dispose();
    super.dispose();
  }
}
