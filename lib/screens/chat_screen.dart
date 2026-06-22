import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/ram_indicator.dart';
import 'settings_screen.dart';
import 'history_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  bool _hasText = false;
  File? _selectedImage;

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
    
    if (_selectedImage != null && provider.isVisionCapable) {
      provider.sendImageMessage(_selectedImage!.path, text);
      setState(() => _selectedImage = null);
    } else {
      provider.sendMessage(text);
    }
    
    _scrollToBottom();
  }

  Future<void> _pickImage(ImageSource source) async {
    final file = await _picker.pickImage(source: source);
    if (file != null) {
      setState(() => _selectedImage = File(file.path));
    }
  }

  void _showImagePicker(ChatProvider provider) {
    if (!provider.isVisionCapable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("This model can't see images — load a vision model"),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        color: AppTheme.bgSurface,
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
                icon: const Icon(Icons.camera_alt_rounded),
                label: const Text('Camera'),
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
                icon: const Icon(Icons.image_rounded),
                label: const Text('Gallery'),
              ),
            ],
          ),
        ),
      ),
    );
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
              // New chat
              IconButton(
                icon: const Icon(Icons.add_comment_rounded),
                tooltip: 'New chat',
                onPressed: provider.messages.isEmpty
                    ? null
                    : () {
                        provider.clearChat();
                        setState(() => _selectedImage = null);
                      },
              ),
              // History
              IconButton(
                icon: const Icon(Icons.history_rounded),
                tooltip: 'Chat history',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: provider,
                      child: const HistoryScreen(),
                    ),
                  ),
                ),
              ),
              // Clear
              if (provider.messages.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Clear chat',
                  onPressed: () => _confirmClear(context, provider),
                ),
              // Settings
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
              // RAM indicator
              const RamIndicator(),
              // Input bar
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
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          ],
        ),
      );

  Widget _inputBar(ChatProvider provider) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        color: AppTheme.bgBase,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Image preview (if selected)
              if (_selectedImage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          _selectedImage!,
                          height: 80,
                          width: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: -8,
                        right: -8,
                        child: GestureDetector(
                          onTap: () => setState(() => _selectedImage = null),
                          child: Container(
                            decoration: const BoxDecoration(
                              color: AppTheme.accentRed,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white, size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Input row
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // ── Image picker button ──────────────────────────────────────
                  GestureDetector(
                    onTap: () => _showImagePicker(provider),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppTheme.bgSurface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: provider.isVisionCapable
                              ? AppTheme.borderColor
                              : AppTheme.borderColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        color: provider.isVisionCapable
                            ? AppTheme.textSecondary
                            : AppTheme.textMuted.withValues(alpha: 0.5),
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Text input
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
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // ── Send / Stop button ────────────────────────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: provider.isGenerating

                        // STOP button
                        ? GestureDetector(
                            key: const ValueKey('stop'),
                            onTap: provider.stopGeneration,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: AppTheme.accentRed.withAlpha(30),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: AppTheme.accentRed.withAlpha(120)),
                              ),
                              child: const Icon(
                                Icons.stop_rounded,
                                color: AppTheme.accentRed,
                                size: 20,
                              ),
                            ),
                          )

                        // SEND button
                        : GestureDetector(
                            key: const ValueKey('send'),
                            onTap: (_hasText || _selectedImage != null)
                                ? () => _send(provider)
                                : null,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: (_hasText || _selectedImage != null)
                                    ? AppTheme.accentAmber.withAlpha(40)
                                    : AppTheme.bgSurface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: (_hasText || _selectedImage != null)
                                      ? AppTheme.accentAmber.withAlpha(150)
                                      : AppTheme.borderColor,
                                ),
                              ),
                              child: Icon(
                                Icons.arrow_upward_rounded,
                                color: (_hasText || _selectedImage != null)
                                    ? AppTheme.accentAmber
                                    : AppTheme.textMuted,
                                size: 20,
                              ),
                            ),
                          ),
                  ),
                ],
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
    if (ok == true) {
      provider.clearChat();
      setState(() => _selectedImage = null);
    }
  }
}
