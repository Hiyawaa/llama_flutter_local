import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../widgets/chat_bubble.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _inputCtrl  = TextEditingController();
  final _focusNode  = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(() {
      final v = _inputCtrl.text.trim().isNotEmpty;
      if (v != _hasText) setState(() => _hasText = v);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send(ChatProvider provider) {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || provider.isGenerating) return;
    _inputCtrl.clear();
    provider.sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        if (provider.messages.isNotEmpty) _scrollToBottom();

        final modelName = provider.llama.loadedPath != null
            ? p.basename(provider.llama.loadedPath!)
            : 'No model';

        return Scaffold(
          backgroundColor: AppTheme.bgBase,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.memory_rounded),
              tooltip: 'Change model',
              onPressed: () => Navigator.pop(context),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🦙 LlamaDart',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                Text(modelName,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
            actions: [
              if (provider.messages.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Clear chat',
                  onPressed: () => _confirmClear(context, provider),
                ),
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Settings',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: provider,
                      child: const SettingsScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: provider.messages.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: provider.messages.length,
                        itemBuilder: (_, i) =>
                            ChatBubble(message: provider.messages[i]),
                      ),
              ),
              _inputBar(provider),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyState() => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('🦙', style: TextStyle(fontSize: 52)),
            SizedBox(height: 12),
            Text('Model loaded — start chatting!',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14)),
          ],
        ),
      );

  Widget _inputBar(ChatProvider provider) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: const BoxDecoration(
          color: AppTheme.bgBase,
          border: Border(top: BorderSide(color: AppTheme.borderColor)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 130),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: TextField(
                    controller: _inputCtrl,
                    focusNode: _focusNode,
                    maxLines: null,
                    enabled: !provider.isGenerating,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 15),
                    decoration: const InputDecoration(
                      hintText: 'Message...',
                      hintStyle: TextStyle(color: AppTheme.textMuted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: provider.isGenerating
                    ? null
                    : () => _send(provider),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (_hasText && !provider.isGenerating)
                        ? AppTheme.accentAmber.withAlpha((0.15 * 255).round())
                        : AppTheme.bgSurface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (_hasText && !provider.isGenerating)
                          ? AppTheme.accentAmber.withAlpha((0.5 * 255).round())
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: provider.isGenerating
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.accentAmber,
                          ),
                        )
                      : Icon(Icons.arrow_upward_rounded,
                          color: _hasText
                              ? AppTheme.accentAmber
                              : AppTheme.textMuted,
                          size: 20),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _confirmClear(
      BuildContext context, ChatProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgSurface,
        title: const Text('Clear chat?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('All messages will be deleted.',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear',
                  style: TextStyle(color: AppTheme.accentRed))),
        ],
      ),
    );
    if (ok == true) provider.clearChat();
  }
}
