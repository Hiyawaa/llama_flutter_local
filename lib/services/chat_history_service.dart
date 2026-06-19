import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ── Models ────────────────────────────────────────────────────────────────────

class SavedMessage {
  final String role;
  final String content;
  final DateTime timestamp;

  SavedMessage({
    required this.role,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };

  factory SavedMessage.fromJson(Map<String, dynamic> j) => SavedMessage(
        role: j['role'] as String,
        content: j['content'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
      );
}

class SavedConversation {
  final String id;
  final String title;
  final DateTime createdAt;
  final String? modelName;
  final List<SavedMessage> messages;

  SavedConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
    this.modelName,
  });

  int get messageCount => messages.length;
  int get userTurns => messages.where((m) => m.role == 'user').length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'modelName': modelName,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory SavedConversation.fromJson(Map<String, dynamic> j) =>
      SavedConversation(
        id: j['id'] as String,
        title: j['title'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        modelName: j['modelName'] as String?,
        messages: (j['messages'] as List<dynamic>)
            .map((m) => SavedMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

// ── Service ───────────────────────────────────────────────────────────────────

class ChatHistoryService {
  static const _dir = 'chat_history';

  Future<Directory> _historyDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, _dir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _filePath(String id) async {
    final dir = await _historyDir();
    return p.join(dir.path, '$id.json');
  }

  /// Save a new conversation (or overwrite by id)
  Future<void> save(SavedConversation conv) async {
    final file = File(await _filePath(conv.id));
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(conv.toJson()));
  }

  /// Load all conversations, sorted newest-first
  Future<List<SavedConversation>> loadAll() async {
    final dir = await _historyDir();
    final files = await dir.list().toList();
    final convs = <SavedConversation>[];

    for (final f in files.whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        convs.add(SavedConversation.fromJson(data));
      } catch (_) {/* skip corrupt files */}
    }

    convs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return convs;
  }

  /// Delete a conversation by id
  Future<void> delete(String id) async {
    final file = File(await _filePath(id));
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteAll() async {
    final dir = await _historyDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
