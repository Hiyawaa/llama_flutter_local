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
import 'image_scanner_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _imagePicker = ImagePicker();
  bool _hasText = false;
  ChatMessage? _replyingTo;
  List<String> _pendingImages = [];
  // Large-paste detection: instead of letting a wall of pasted text (a
  // stack trace, a whole file, a long article) fill the input field and
  // make composing an actual message awkward, we collapse it into a
  // compact "PASTED" attachment chip — mirroring how Claude's own chat
  // input handles large pastes. Flutter has no cross-platform "did the
  // user just paste" event, so this uses a practical heuristic instead:
  // if the text field's length jumps by more than [_pasteThreshold]
  // characters in a single change, it's treated as a paste rather than
  // fast typing.
  static const int _pasteThreshold = 300;
  String? _pastedText;
  String _lastKnownText = '';

  // Feature 4 (Multi-Turn Vision): capped rather than unlimited. Each
  // attached image adds real memory pressure during mmproj encoding on a
  // 4GB device, and (per llama_service.dart) only the first image is
  // guaranteed to actually reach the model this turn if the engine
  // doesn't support multi-image content — so there's no upside to
  // letting the user attach a dozen photos.
  static const int _maxImagesPerMessage = 4;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(() {
      final newText = _inputCtrl.text;
      final delta = newText.length - _lastKnownText.length;

      if (delta > _pasteThreshold) {
        // Treat this as a paste: lift it out into an attachment chip and
        // clear the visible field so the user has a clean line to add
        // their own commentary before sending.
        final captured = newText;
        _lastKnownText = '';
        _inputCtrl.clear();
        setState(() {
          _pastedText = captured;
        });
        return;
      }

      _lastKnownText = newText;
      final v = newText.trim().isNotEmpty;
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

  void _startReply(ChatMessage message) {
    setState(() => _replyingTo = message);
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
  }

  void _send(ChatProvider provider) {
    final text = _inputCtrl.text.trim();
    final hasPaste = _pastedText != null;
    if ((text.isEmpty && _pendingImages.isEmpty && !hasPaste) ||
        provider.isGenerating) {
      return;
    }

    final reply = _replyingTo;
    final images = List<String>.from(_pendingImages);
    final paste = _pastedText;
    _inputCtrl.clear();
    setState(() {
      _replyingTo = null;
      _pendingImages = [];
      _pastedText = null;
    });

    // Fold the quoted message into the outgoing prompt so the model has
    // context, without permanently mutating what's shown in the bubble.
    var outgoing = reply == null
        ? text
        : '> ${_quotePreview(reply.content, maxLen: 400)}\n\n$text';

    // Fold the pasted attachment in as a fenced block, with the user's
    // typed commentary (if any) leading it — same order Claude's own
    // input uses: your own words first, then the pasted content beneath.
    if (paste != null) {
      final commentary = outgoing.trim();
      outgoing = commentary.isEmpty
          ? '```\n$paste\n```'
          : '$commentary\n\n```\n$paste\n```';
    }

    provider.sendMessage(outgoing, imagePaths: images);
    _scrollToBottom();
  }

  Future<void> _pickImages() async {
    try {
      final remaining = _maxImagesPerMessage - _pendingImages.length;
      if (remaining <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Up to $_maxImagesPerMessage images per message')),
        );
        return;
      }
      final picked = await _imagePicker.pickMultiImage(limit: remaining);
      if (picked.isEmpty) return;
      setState(() {
        _pendingImages.addAll(picked.take(remaining).map((x) => x.path));
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open image picker: $e')),
      );
    }
  }

  Future<void> _takePhoto() async {
    try {
      if (_pendingImages.length >= _maxImagesPerMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Up to $_maxImagesPerMessage images per message')),
        );
        return;
      }
      final photo = await _imagePicker.pickImage(source: ImageSource.camera);
      if (photo == null) return;
      setState(() => _pendingImages.add(photo.path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open camera: $e')),
      );
    }
  }

  /// Feature 4: single visible entry point for every way to get an image
  /// into the chat, instead of splitting "camera" behind one gesture and
  /// "scan & crop" behind another undiscoverable one (a long-press, which
  /// a user has no way to know exists without being told).
  void _showImageOptions() {
    final provider = context.read<ChatProvider>();
    if (!provider.llama.hasVision) {
      final reason = provider.ramWarning != null
          ? 'The vision projector for this model was skipped: ${provider.ramWarning}'
          : 'This model has no vision projector (mmproj) loaded, so it '
              'can\'t read images. Load a matching vision model, or check '
              'that its mmproj file is in the same folder and was '
              'detected on load.';
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgSurface,
          title: const Text('No vision support loaded',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
          content: Text(reason,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK',
                  style: TextStyle(color: AppTheme.accentAmber)),
            ),
          ],
        ),
      );
      return;
    }
    _showImageOptionsMenu();
  }

  void _showImageOptionsMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Add image',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded,
                  color: AppTheme.accentAmber),
              title: const Text('Take photo',
                  style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded,
                  color: AppTheme.accentAmber),
              title: const Text('Choose from gallery',
                  style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: const Text('Select multiple photos',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _pickImages();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.crop_rounded, color: AppTheme.accentAmber),
              title: const Text('Scan & crop',
                  style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: const Text('Crop before sending',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ImageScannerScreen()),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _removePendingImage(String path) {
    setState(() => _pendingImages.remove(path));
  }

  void _removePaste() {
    setState(() => _pastedText = null);
  }

  String _quotePreview(String content, {int maxLen = 120}) {
    final oneLine = content.trim().replaceAll('\n', ' ');
    return oneLine.length > maxLen
        ? '${oneLine.substring(0, maxLen)}…'
        : oneLine;
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
                const Text(
                  '🦙 LlamaDart',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  modelName,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              // RAG documents (Feature 3)
              IconButton(
                icon: Icon(
                  Icons.folder_special_outlined,
                  color: provider.ragEnabled ? AppTheme.accentAmber : null,
                ),
                tooltip: 'RAG documents',
                onPressed: () => Navigator.pushNamed(context, '/rag-documents'),
              ),
              // New chat
              IconButton(
                icon: const Icon(Icons.add_comment_rounded),
                tooltip: 'New chat',
                onPressed: provider.messages.isEmpty
                    ? null
                    : () {
                        provider.clearChat();
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
              // Surfaces the "vision projector skipped due to low RAM"
              // warning that ChatProvider.loadModel sets but which was
              // previously silent — the whole point of RamGuard's
              // guardrails is defeated if the user can't actually see
              // when a guardrail fired.
              if (provider.ramWarning != null) _ramWarningBanner(provider),
              Expanded(
                child: provider.messages.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: provider.messages.length,
                        itemBuilder: (_, i) => ChatBubble(
                          message: provider.messages[i],
                          onReply: _startReply,
                        ),
                      ),
              ),
              // RAM indicator
              const RamIndicator(),
              // Reply preview
              if (_replyingTo != null) _replyPreview(_replyingTo!),
              // Pending image thumbnails (Feature 4)
              if (_pendingImages.isNotEmpty) _pendingImagesRow(),
              if (_pastedText != null) _pastedTextChip(),
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
            Text(
              'Model loaded — start chatting!',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );

  Widget _replyPreview(ChatMessage message) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(color: AppTheme.accentAmber, width: 3),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.role == 'user'
                        ? 'Replying to yourself'
                        : 'Replying to 🦙',
                    style: const TextStyle(
                      color: AppTheme.accentAmber,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _quotePreview(message.content),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppTheme.textMuted,
              onPressed: _cancelReply,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
            ),
          ],
        ),
      );

  Widget _ramWarningBanner(ChatProvider provider) => Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.accentRed.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accentRed.withAlpha(70)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.memory_rounded,
                size: 16, color: AppTheme.accentRed),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                provider.ramWarning!,
                style: const TextStyle(color: AppTheme.accentRed, fontSize: 12),
              ),
            ),
            GestureDetector(
              onTap: provider.dismissRamWarning,
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.close_rounded,
                    size: 16, color: AppTheme.accentRed),
              ),
            ),
          ],
        ),
      );

  Widget _pastedTextChip() {
    final text = _pastedText ?? '';
    final lineCount = '\n'.allMatches(text).length + 1;
    final preview = text.length > 160 ? '${text.substring(0, 160)}…' : text;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxWidth: 220),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  preview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
              GestureDetector(
                onTap: _removePaste,
                child: const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.close_rounded,
                      size: 14, color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlue.withAlpha(30),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: AppTheme.accentBlue.withAlpha(90)),
                ),
                child: const Text(
                  'PASTED',
                  style: TextStyle(
                    color: AppTheme.accentBlue,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$lineCount line${lineCount == 1 ? '' : 's'} · ${text.length} chars',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pendingImagesRow() => Container(
        height: 68,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingImages.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final path = _pendingImages[i];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(path),
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: -4,
                  right: -4,
                  child: GestureDetector(
                    onTap: () => _removePendingImage(path),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: AppTheme.bgBase,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 14, color: AppTheme.accentRed),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

  Widget _inputBar(ChatProvider provider) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        color: AppTheme.bgBase,
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // ── Multi-image picker button (Feature 4) ────────────────────
              // Tap = quick multi-image picker (attaches to this chat
              // message). Long-press = dedicated crop-enabled scan screen,
              // for when you want to crop before sending. One button, two
              // ways in, instead of two separate buttons that looked
              // identical and did almost the same thing.
              GestureDetector(
                onTap: _showImageOptions,
                child: Opacity(
                  opacity: provider.llama.hasVision ? 1.0 : 0.45,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _pendingImages.isNotEmpty
                          ? AppTheme.accentBlue.withAlpha(30)
                          : AppTheme.bgSurface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _pendingImages.isNotEmpty
                            ? AppTheme.accentBlue.withAlpha(150)
                            : AppTheme.borderColor,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.image_search_rounded,
                          color: _pendingImages.isNotEmpty
                              ? AppTheme.accentBlue
                              : AppTheme.textSecondary,
                          size: 20,
                        ),
                        if (_pendingImages.isNotEmpty)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: const BoxDecoration(
                                color: AppTheme.accentBlue,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${_pendingImages.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
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
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: _replyingTo != null ? 'Reply...' : 'Message...',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
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
                              color: AppTheme.accentRed.withAlpha(120),
                            ),
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
                        onTap: (_hasText ||
                                _pendingImages.isNotEmpty ||
                                _pastedText != null)
                            ? () => _send(provider)
                            : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: (_hasText ||
                                    _pendingImages.isNotEmpty ||
                                    _pastedText != null)
                                ? AppTheme.accentAmber.withAlpha(40)
                                : AppTheme.bgSurface,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (_hasText ||
                                      _pendingImages.isNotEmpty ||
                                      _pastedText != null)
                                  ? AppTheme.accentAmber.withAlpha(150)
                                  : AppTheme.borderColor,
                            ),
                          ),
                          child: Icon(
                            Icons.arrow_upward_rounded,
                            color: (_hasText ||
                                    _pendingImages.isNotEmpty ||
                                    _pastedText != null)
                                ? AppTheme.accentAmber
                                : AppTheme.textMuted,
                            size: 20,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );

  Future<void> _confirmClear(
    BuildContext context,
    ChatProvider provider,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgSurface,
        title: const Text(
          'Clear chat?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: const Text(
          'All messages will be deleted.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Clear',
              style: TextStyle(color: AppTheme.accentRed),
            ),
          ),
        ],
      ),
    );
    if (ok == true) provider.clearChat();
  }
}
