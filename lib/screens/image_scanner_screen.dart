import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

/// Image Scanner — lets the user attach a photo and ask the currently
/// loaded model about it. Uses whatever model is already loaded in
/// [ChatProvider]; there is no separate model-loading step here. If the
/// loaded model has no vision projector, this screen isn't reachable (the
/// "+" button in chat is disabled in that case) but we still guard for it.
class ImageScannerScreen extends StatefulWidget {
  const ImageScannerScreen({super.key});

  @override
  State<ImageScannerScreen> createState() => _ImageScannerScreenState();
}

class _ImageScannerScreenState extends State<ImageScannerScreen> {
  final _picker = ImagePicker();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _hasText = false;

  // The image currently staged for the next message. Once sent, it travels
  // with that ChatMessage and shows up in the normal chat history.
  String? _stagedImagePath;

  // Quick-prompt suggestions
  static const _suggestions = [
    'Describe this image in detail',
    'What text can you read in this image?',
    'What objects are in this image?',
    'Explain what is happening in this image',
    'What emotions does this image convey?',
    'Is there any math or equations? Solve them',
    'Translate any text visible in this image',
    'What is the main subject of this image?',
  ];

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
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
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

  Future<void> _pickFromCamera() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (xfile == null) return;
    if (mounted) setState(() => _stagedImagePath = xfile.path);
  }

  Future<void> _pickFromGallery() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (xfile == null) return;
    if (mounted) setState(() => _stagedImagePath = xfile.path);
  }

  void _clearStagedImage() => setState(() => _stagedImagePath = null);

  Future<void> _send(ChatProvider provider) async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || provider.isGenerating) return;
    _inputCtrl.clear();

    if (_stagedImagePath != null) {
      final imagePath = _stagedImagePath!;
      // Clear the staged image immediately — it now travels with the
      // message itself, so the input area returns to its normal state for
      // the next (text-only, same-context) follow-up.
      setState(() => _stagedImagePath = null);
      await provider.sendImageMessage(imagePath, text);
    } else {
      // Text-only follow-up about a previously sent image — the model still
      // has it in context via conversation history.
      await provider.sendMessage(text);
    }
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        if (provider.messages.isNotEmpty) _scrollToBottom();

        final canScan = provider.llama.isReady && provider.isVisionCapable;

        return Scaffold(
          backgroundColor: AppTheme.bgBase,
          appBar: AppBar(
            title: const Text('🔍 Image Scanner'),
            actions: [
              if (_stagedImagePath != null)
                IconButton(
                  icon: const Icon(Icons.clear_rounded),
                  tooltip: 'Remove image',
                  onPressed: _clearStagedImage,
                ),
            ],
          ),
          body: Column(
            children: [
              // ── Not capable banner ────────────────────────────────────
              if (!canScan) _NotCapableBanner(provider: provider),

              // ── Main content ──────────────────────────────────────────
              Expanded(
                child: !canScan
                    ? const SizedBox.shrink()
                    : _stagedImagePath == null && provider.messages.isEmpty
                        ? _ImagePickerArea(
                            onCamera: _pickFromCamera,
                            onGallery: _pickFromGallery,
                          )
                        : _ChatArea(
                            provider: provider,
                            scrollCtrl: _scrollCtrl,
                            stagedImagePath: _stagedImagePath,
                            onClearStaged: _clearStagedImage,
                            suggestions: _suggestions,
                            onSuggestion: (s) {
                              _inputCtrl.text = s;
                              _send(provider);
                            },
                            onPickNew: () => _showImageOptions(context),
                          ),
              ),

              // ── Input bar ──────────────────────────────────────────────
              if (canScan &&
                  (_stagedImagePath != null || provider.messages.isNotEmpty))
                _InputBar(
                  ctrl: _inputCtrl,
                  hasText: _hasText,
                  isGenerating: provider.isGenerating,
                  hasStagedImage: _stagedImagePath != null,
                  onAttach: () => _showImageOptions(context),
                  onSend: () => _send(provider),
                  onStop: provider.stopGeneration,
                ),
            ],
          ),
        );
      },
    );
  }

  void _showImageOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: AppTheme.textMuted,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            _SheetOption(
              icon: Icons.camera_alt_rounded,
              label: 'Take photo',
              onTap: () {
                Navigator.pop(context);
                _pickFromCamera();
              },
            ),
            _SheetOption(
              icon: Icons.photo_library_rounded,
              label: 'Choose from gallery',
              onTap: () {
                Navigator.pop(context);
                _pickFromGallery();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Not capable banner ────────────────────────────────────────────────────────

class _NotCapableBanner extends StatelessWidget {
  final ChatProvider provider;
  const _NotCapableBanner({required this.provider});

  @override
  Widget build(BuildContext context) {
    final noModel = !provider.llama.isReady;
    final message = noModel
        ? 'No model loaded — go back and load a model first'
        : "This model can't see images — load a vision model "
            "(e.g. Qwen2-VL-2B) from the model picker";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: AppTheme.bgSurface,
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppTheme.accentAmber, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: const Text('Go back',
                style: TextStyle(
                    color: AppTheme.accentAmber,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ── Image picker area ─────────────────────────────────────────────────────────
// Wrapped in a scroll view so smaller screens never overflow — this was the
// cause of the "BOTTOM OVERFLOWED BY N PIXELS" hazard-stripe bug.

class _ImagePickerArea extends StatelessWidget {
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  const _ImagePickerArea({required this.onCamera, required this.onGallery});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppTheme.bgSurface,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: const Icon(Icons.image_search_rounded,
                  size: 44, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 24),
            const Text('Scan an image with AI',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Take a photo or pick from gallery\nAsk anything about the image',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: _BigBtn(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    color: AppTheme.accentAmber,
                    onTap: onCamera,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _BigBtn(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    color: AppTheme.accentGreen,
                    onTap: onGallery,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const _UseCasesBox(),
          ],
        ),
      );
}

class _BigBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _BigBtn(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(
                      color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
}

class _UseCasesBox extends StatelessWidget {
  const _UseCasesBox();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💡 What you can do',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              '• Read and solve math equations in photos\n'
              '• Translate text from images\n'
              '• Describe scenes, objects, people\n'
              '• Extract text (OCR-like)\n'
              '• Analyze charts and diagrams\n'
              '• Ask follow-up questions about the image',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      );
}

// ── Chat area with image ──────────────────────────────────────────────────────

class _ChatArea extends StatelessWidget {
  final ChatProvider provider;
  final ScrollController scrollCtrl;
  final String? stagedImagePath;
  final VoidCallback onClearStaged;
  final List<String> suggestions;
  final void Function(String) onSuggestion;
  final VoidCallback onPickNew;

  const _ChatArea({
    required this.provider,
    required this.scrollCtrl,
    required this.stagedImagePath,
    required this.onClearStaged,
    required this.suggestions,
    required this.onSuggestion,
    required this.onPickNew,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.all(12),
      children: [
        // Staged (not-yet-sent) image preview
        if (stagedImagePath != null) ...[
          _ImagePreview(path: stagedImagePath!, onChange: onClearStaged),
          const SizedBox(height: 12),
        ],

        // Suggestions (only when there's a staged image and no messages yet)
        if (stagedImagePath != null && provider.messages.isEmpty) ...[
          const Text('Quick prompts',
              style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: suggestions
                .map((s) => GestureDetector(
                      onTap: () => onSuggestion(s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.bgSurface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        child: Text(s,
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
        ],

        // Messages — reuses the same bubble style as the main chat screen's
        // model, just rendered locally here for the scanner's own message
        // list view (provider.messages already includes image attachments).
        ...provider.messages.map((m) => _ScannerBubble(message: m)),

        if (provider.messages.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: onPickNew,
              icon: const Icon(Icons.swap_horiz_rounded,
                  size: 16, color: AppTheme.accentGreen),
              label: const Text('Scan a different image',
                  style: TextStyle(
                      color: AppTheme.accentGreen,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ],
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final String path;
  final VoidCallback onChange;
  const _ImagePreview({required this.path, required this.onChange});

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(
              File(path),
              width: double.infinity,
              height: 220,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: onChange,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
}

// ── Scanner chat bubble ────────────────────────────────────────────────────────
// Lightweight bubble tailored to this screen (keeps the existing visual
// language) — shows the attached image inline with the user's turn.

class _ScannerBubble extends StatelessWidget {
  final ChatMessage message;
  const _ScannerBubble({required this.message});

  bool get isUser => message.role == 'user';

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.accentAmber.withValues(alpha: 0.12),
                  border: Border.all(
                      color: AppTheme.accentAmber.withValues(alpha: 0.35)),
                ),
                child: const Center(
                    child: Text('🔍', style: TextStyle(fontSize: 13))),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: GestureDetector(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: message.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Copied'),
                        duration: Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating),
                  );
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser ? AppTheme.bgBubbleUser : AppTheme.bgBubbleAI,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(isUser ? 16 : 4),
                      topRight: Radius.circular(isUser ? 4 : 16),
                      bottomLeft: const Radius.circular(16),
                      bottomRight: const Radius.circular(16),
                    ),
                    border: Border.all(
                      color: isUser
                          ? AppTheme.accentGreen.withValues(alpha: 0.2)
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.imagePath != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(message.imagePath!),
                            width: 160,
                            height: 160,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 160,
                              height: 100,
                              alignment: Alignment.center,
                              color: AppTheme.bgBase,
                              child: const Icon(Icons.broken_image_outlined,
                                  color: AppTheme.textMuted),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      message.content.isEmpty && message.isStreaming
                          ? _dots()
                          : SelectableText(
                              message.content,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 14.5,
                                  height: 1.6),
                            ),
                    ],
                  ),
                ),
              ),
            ),
            if (isUser) const SizedBox(width: 36),
          ],
        ),
      );

  Widget _dots() => const SizedBox(
        height: 20,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dot(delay: 0),
            SizedBox(width: 4),
            _Dot(delay: 200),
            SizedBox(width: 4),
            _Dot(delay: 400),
          ],
        ),
      );
}

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _anim,
        child: Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
                color: AppTheme.accentAmber, shape: BoxShape.circle)),
      );
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool hasText;
  final bool isGenerating;
  final bool hasStagedImage;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _InputBar({
    required this.ctrl,
    required this.hasText,
    required this.isGenerating,
    required this.hasStagedImage,
    required this.onAttach,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) => Container(
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
              // Attach another image
              GestureDetector(
                onTap: isGenerating ? null : onAttach,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.bgSurface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hasStagedImage
                          ? AppTheme.accentGreen.withValues(alpha: 0.5)
                          : AppTheme.borderColor,
                    ),
                  ),
                  child: Icon(
                    Icons.add_photo_alternate_outlined,
                    color: hasStagedImage
                        ? AppTheme.accentGreen
                        : AppTheme.textSecondary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: TextField(
                    controller: ctrl,
                    maxLines: null,
                    enabled: !isGenerating,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: hasStagedImage
                          ? 'Ask about this image...'
                          : 'Ask a follow-up...',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isGenerating
                    ? GestureDetector(
                        key: const ValueKey('stop'),
                        onTap: onStop,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.accentRed.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color:
                                    AppTheme.accentRed.withValues(alpha: 0.5)),
                          ),
                          child: const Icon(Icons.stop_rounded,
                              color: AppTheme.accentRed, size: 20),
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('send'),
                        onTap: hasText ? onSend : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: hasText
                                ? AppTheme.accentAmber.withValues(alpha: 0.15)
                                : AppTheme.bgSurface,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: hasText
                                  ? AppTheme.accentAmber.withValues(alpha: 0.5)
                                  : AppTheme.borderColor,
                            ),
                          ),
                          child: Icon(Icons.arrow_upward_rounded,
                              color: hasText
                                  ? AppTheme.accentAmber
                                  : AppTheme.textMuted,
                              size: 20),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
}

// ── Sheet option ──────────────────────────────────────────────────────────────

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SheetOption(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: AppTheme.accentAmber),
        title: Text(label, style: const TextStyle(color: AppTheme.textPrimary)),
        onTap: onTap,
      );
}
