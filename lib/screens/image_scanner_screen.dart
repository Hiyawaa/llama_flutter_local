import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:provider/provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../services/ml_kit_service.dart';

class ImageScannerScreen extends StatefulWidget {
  const ImageScannerScreen({super.key});

  @override
  State<ImageScannerScreen> createState() => _ImageScannerScreenState();
}

class _ImageScannerScreenState extends State<ImageScannerScreen>
    with SingleTickerProviderStateMixin {
  final _picker = ImagePicker();
  final _mlKit = MlKitService();

  String? _imagePath;
  MlKitResult? _result;
  bool _scanning = false;

  // Toggles for which analyses to run
  bool _doOcr = true;
  bool _doLabeling = true;
  bool _doBarcode = true;

  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _mlKit.dispose();
    super.dispose();
  }

  // ── Image picking + cropping ─────────────────────────────────────────────

  Future<void> _pickCamera() async {
    final f =
        await _picker.pickImage(source: ImageSource.camera, imageQuality: 90);
    if (f == null) return;
    final cropped = await _crop(f.path);
    if (cropped != null) await _analyze(cropped);
  }

  Future<void> _pickGallery() async {
    final f =
        await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (f == null) return;
    final cropped = await _crop(f.path);
    if (cropped != null) await _analyze(cropped);
  }

  Future<String?> _crop(String sourcePath) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: const Color(0xFF0F0F11),
          toolbarWidgetColor: const Color(0xFFF59E0B),
          backgroundColor: const Color(0xFF0F0F11),
          activeControlsWidgetColor: const Color(0xFFF59E0B),
          dimmedLayerColor: const Color(0xAA000000),
          cropFrameColor: const Color(0xFFF59E0B),
          cropGridColor: const Color(0x55F59E0B),
          cropFrameStrokeWidth: 3,
          showCropGrid: true,
          lockAspectRatio: false,
          hideBottomControls: false,
          initAspectRatio: CropAspectRatioPreset.original,
        ),
      ],
    );
    return cropped?.path;
  }

  Future<void> _analyze(String path) async {
    setState(() {
      _imagePath = path;
      _result = null;
      _scanning = true;
    });

    final result = await _mlKit.analyzeImage(
      path,
      doOcr: _doOcr,
      doLabeling: _doLabeling,
      doBarcode: _doBarcode,
    );

    if (mounted) {
      setState(() {
        _result = result;
        _scanning = false;
      });
      if (!result.isEmpty) _autoAnalyze(result);
    }
  }

  // ── Content-type detection ────────────────────────────────────────────────

  bool _looksLikeMath(String text) {
    return RegExp(
      r'[0-9]+[\s]*[+\-*/^=]|'
      r'[0-9]{1,3}(,[0-9]{3})+|'
      r'[0-9]+\.[0-9]+|'
      r'%|RATE|INTEREST|COMPOUND|'
      r'COST|PRICE|TOTAL|SUM|BAC|'
      r'LOG|SIN|COS|TAN|'
      r'[A-Z]{2,}\s*=\s*[0-9]',
      caseSensitive: false,
    ).hasMatch(text);
  }

  bool _looksLikeExamProblem(String text) {
    return RegExp(
      r'BOARD|EXAM|[0-9]{4}|PROBLEM|FIND|COMPUTE|DETERMINE|CALCULATE|'
      r'CE BOARD|ME BOARD|EE BOARD|ECE BOARD|GIVEN|REQUIRED|SOLUTION',
      caseSensitive: false,
    ).hasMatch(text);
  }

  String _buildPrompt(MlKitResult r) {
    if (r.hasBarcodes) {
      final val = r.barcodes.first;
      if (val.startsWith('http')) return 'What is this URL? $val';
      return 'What does this code mean? $val';
    }

    final text = r.recognizedText ?? '';

    if (r.hasLabels && !r.hasText) {
      return 'Image shows: \${r.labels.take(4).join(", ")}. Describe briefly.';
    }
    if (text.isEmpty) {
      return 'Image labels: \${r.labels.take(4).join(", ")}. What is this?';
    }

    final isExam = _looksLikeExamProblem(text);
    final isMath = _looksLikeMath(text);
    final isNonEng = text.runes.any((c) => c > 127);

    if (isExam || isMath) {
      return 'The following is OCR text from a photo of an exam problem. '
          'The text may have OCR errors (wrong letters, missing spaces, '
          'garbled numbers). First reconstruct the most likely intended '
          'problem, then solve it step by step.\n\nOCR text:\n$text';
    }
    if (isNonEng) {
      return 'OCR text (may have errors). Translate to English '
          'and fix any obvious OCR mistakes:\n$text';
    }
    return 'OCR text (may have errors). Clean up and summarize:\n$text';
  }

  void _autoAnalyze(MlKitResult result) {
    final provider = context.read<ChatProvider>();
    if (!provider.llama.isReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Load a model on the home screen to auto-analyze'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    final prompt = _buildPrompt(result);
    provider.sendMessage(prompt);
    Navigator.popUntil(context, (r) => r.isFirst);
    Navigator.pushNamed(context, '/chat');
  }

  // ── Manual send button (fallback) ─────────────────────────────────────────

  void _sendToChat(BuildContext ctx) {
    if (_result == null) return;
    final provider = ctx.read<ChatProvider>();
    if (!provider.llama.isReady) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Load a text model to analyze results'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    provider.sendMessage(_buildPrompt(_result!));
    Navigator.popUntil(ctx, (r) => r.isFirst);
    Navigator.pushNamed(ctx, '/chat');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: const Text('🔍 Image Scanner'),
        actions: [
          // Settings toggle
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Scan options',
            onPressed: () => _showOptions(context),
          ),
          if (_imagePath != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'New scan',
              onPressed: () => setState(() {
                _imagePath = null;
                _result = null;
              }),
            ),
        ],
      ),
      body: _imagePath == null
          ? _PickerArea(onCamera: _pickCamera, onGallery: _pickGallery)
          : _ScanArea(
              imagePath: _imagePath!,
              result: _result,
              scanning: _scanning,
              tabCtrl: _tabCtrl,
              onRescan: () => _analyze(_imagePath!),
              onNewImage: () => _showPickSheet(context),
              onSendToChat: () => _sendToChat(context),
              onCrop: () async {
                final cropped = await _crop(_imagePath!);
                if (cropped != null) _analyze(cropped);
              },
            ),
    );
  }

  void _showPickSheet(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
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
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded,
                  color: AppTheme.accentAmber),
              title: const Text('Take photo',
                  style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _pickCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded,
                  color: AppTheme.accentGreen),
              title: const Text('Choose from gallery',
                  style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _pickGallery();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: AppTheme.bgSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => StatefulBuilder(
        builder: (ctx2, setInner) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SCAN OPTIONS',
                    style: TextStyle(
                        color: AppTheme.accentAmber,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
                const SizedBox(height: 12),
                _ToggleRow(
                  icon: Icons.text_fields_rounded,
                  label: 'Text Recognition (OCR)',
                  value: _doOcr,
                  onChanged: (v) {
                    setInner(() => _doOcr = v);
                    setState(() => _doOcr = v);
                  },
                ),
                _ToggleRow(
                  icon: Icons.label_outline_rounded,
                  label: 'Image Labeling',
                  value: _doLabeling,
                  onChanged: (v) {
                    setInner(() => _doLabeling = v);
                    setState(() => _doLabeling = v);
                  },
                ),
                _ToggleRow(
                  icon: Icons.qr_code_scanner_rounded,
                  label: 'Barcode / QR Scanning',
                  value: _doBarcode,
                  onChanged: (v) {
                    setInner(() => _doBarcode = v);
                    setState(() => _doBarcode = v);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Picker area ───────────────────────────────────────────────────────────────

class _PickerArea extends StatelessWidget {
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  const _PickerArea({required this.onCamera, required this.onGallery});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
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
                child: const Icon(Icons.document_scanner_rounded,
                    size: 44, color: AppTheme.accentAmber),
              ),
              const SizedBox(height: 24),
              const Text('Image Scanner',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Extract text, identify objects\nand scan QR/barcodes — fully offline',
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
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _BigBtn(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    color: AppTheme.accentGreen,
                    onTap: onGallery,
                  )),
                ],
              ),
              const SizedBox(height: 28),
              // Feature chips
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: const [
                  _FeatureChip('📝 OCR Text'),
                  _FeatureChip('🏷 Object Labels'),
                  _FeatureChip('📦 QR & Barcodes'),
                  _FeatureChip('✈️ Offline'),
                  _FeatureChip('⚡ Fast'),
                  _FeatureChip('🔒 Private'),
                ],
              ),
            ],
          ),
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
          padding: const EdgeInsets.symmetric(vertical: 18),
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

class _FeatureChip extends StatelessWidget {
  final String label;
  const _FeatureChip(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Text(label,
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      );
}

// ── Scan result area ──────────────────────────────────────────────────────────

class _ScanArea extends StatelessWidget {
  final String imagePath;
  final MlKitResult? result;
  final bool scanning;
  final TabController tabCtrl;
  final VoidCallback onRescan;
  final VoidCallback onNewImage;
  final VoidCallback onSendToChat;
  final VoidCallback onCrop;

  const _ScanArea({
    required this.imagePath,
    required this.result,
    required this.scanning,
    required this.tabCtrl,
    required this.onRescan,
    required this.onNewImage,
    required this.onSendToChat,
    required this.onCrop,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Image preview
        Stack(
          children: [
            SizedBox(
              width: double.infinity,
              height: 200,
              child: Image.file(File(imagePath), fit: BoxFit.cover),
            ),
            // Scanning overlay
            if (scanning)
              Container(
                width: double.infinity,
                height: 200,
                color: Colors.black54,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: AppTheme.accentAmber),
                    SizedBox(height: 12),
                    Text('Scanning image...',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            // Action buttons overlay
            Positioned(
              bottom: 8,
              right: 8,
              child: Row(
                children: [
                  _ImgBtn(
                      icon: Icons.swap_horiz_rounded,
                      tooltip: 'New image',
                      onTap: onNewImage),
                  const SizedBox(width: 6),
                  _ImgBtn(
                      icon: Icons.crop_rounded,
                      tooltip: 'Crop & re-scan',
                      onTap: onCrop),
                  const SizedBox(width: 6),
                  _ImgBtn(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Re-scan',
                      onTap: onRescan),
                ],
              ),
            ),
          ],
        ),

        // Speed badge
        if (result != null && !scanning)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: AppTheme.bgSurface,
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded,
                    color: AppTheme.accentAmber, size: 14),
                const SizedBox(width: 4),
                Text(
                  'Scanned in ${result!.duration.inMilliseconds}ms  •  '
                  '${_summary(result!)}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
                const Spacer(),
                if (!result!.isEmpty)
                  GestureDetector(
                    onTap: onSendToChat,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.accentGreen.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppTheme.accentGreen.withValues(alpha: 0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              color: AppTheme.accentGreen, size: 12),
                          SizedBox(width: 4),
                          Text('Send to chat',
                              style: TextStyle(
                                  color: AppTheme.accentGreen,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

        // Tab bar
        Container(
          color: AppTheme.bgSurface,
          child: TabBar(
            controller: tabCtrl,
            labelColor: AppTheme.accentAmber,
            unselectedLabelColor: AppTheme.textMuted,
            indicatorColor: AppTheme.accentAmber,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: [
              Tab(
                  text:
                      'Text${_badge(result?.recognizedText?.isNotEmpty == true)}'),
              Tab(text: 'Labels${_badge(result?.hasLabels == true)}'),
              Tab(text: 'QR/Bar${_badge(result?.hasBarcodes == true)}'),
            ],
          ),
        ),

        // Tab views
        Expanded(
          child: scanning
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.accentAmber))
              : result == null
                  ? const Center(
                      child: Text('Scan an image above',
                          style: TextStyle(color: AppTheme.textMuted)))
                  : TabBarView(
                      controller: tabCtrl,
                      children: [
                        _TextTab(result: result!),
                        _LabelsTab(result: result!),
                        _BarcodesTab(result: result!),
                      ],
                    ),
        ),
      ],
    );
  }

  String _badge(bool has) => has ? ' ✓' : '';

  String _summary(MlKitResult r) {
    final parts = <String>[];
    if (r.hasText) parts.add('text found');
    if (r.hasLabels) parts.add('${r.labels.length} labels');
    if (r.hasBarcodes) parts.add('${r.barcodes.length} code(s)');
    if (r.isEmpty) parts.add('nothing detected');
    return parts.join(' · ');
  }
}

class _ImgBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ImgBtn(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      );
}

// ── Text tab ──────────────────────────────────────────────────────────────────

class _TextTab extends StatefulWidget {
  final MlKitResult result;
  const _TextTab({required this.result});

  @override
  State<_TextTab> createState() => _TextTabState();
}

class _TextTabState extends State<_TextTab> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(
        ClipboardData(text: widget.result.recognizedText ?? ''));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.result.hasText) {
      return const _EmptyTab(
        icon: Icons.text_fields_rounded,
        message: 'No text detected',
        hint: 'Make sure text is clear, well-lit and in focus',
      );
    }
    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(
            children: [
              Text(
                '${widget.result.recognizedText!.split('\n').length} lines',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _copy,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color:
                        (_copied ? AppTheme.accentGreen : AppTheme.accentAmber)
                            .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_copied
                              ? AppTheme.accentGreen
                              : AppTheme.accentAmber)
                          .withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 13,
                        color: _copied
                            ? AppTheme.accentGreen
                            : AppTheme.accentAmber,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _copied ? 'Copied!' : 'Copy all',
                        style: TextStyle(
                          color: _copied
                              ? AppTheme.accentGreen
                              : AppTheme.accentAmber,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Text content
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                widget.result.recognizedText!,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14.5,
                  height: 1.6,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Labels tab ────────────────────────────────────────────────────────────────

class _LabelsTab extends StatelessWidget {
  final MlKitResult result;
  const _LabelsTab({required this.result});

  @override
  Widget build(BuildContext context) {
    if (!result.hasLabels) {
      return const _EmptyTab(
        icon: Icons.label_outline_rounded,
        message: 'No objects detected',
        hint: 'Try a photo with clear, recognizable objects',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: result.labels.length,
      itemBuilder: (_, i) {
        final parts = result.labels[i].split(' (');
        final name = parts[0];
        final conf = parts.length > 1 ? parts[1].replaceAll(')', '') : '';
        final pct = int.tryParse(conf.replaceAll('%', '')) ?? 0;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(
            children: [
              const Text('🏷', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              // Confidence bar
              SizedBox(
                width: 60,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$pct%',
                        style: const TextStyle(
                            color: AppTheme.accentAmber,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: pct / 100,
                        minHeight: 4,
                        backgroundColor: AppTheme.borderColor,
                        valueColor: AlwaysStoppedAnimation(
                          pct > 80
                              ? AppTheme.accentGreen
                              : pct > 60
                                  ? AppTheme.accentAmber
                                  : AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Barcodes tab ──────────────────────────────────────────────────────────────

class _BarcodesTab extends StatelessWidget {
  final MlKitResult result;
  const _BarcodesTab({required this.result});

  @override
  Widget build(BuildContext context) {
    if (!result.hasBarcodes) {
      return const _EmptyTab(
        icon: Icons.qr_code_scanner_rounded,
        message: 'No barcodes or QR codes detected',
        hint: 'Scan a product barcode, QR code, or URL',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: result.barcodes.length,
      itemBuilder: (_, i) {
        final value = result.barcodes[i];
        final isUrl =
            value.startsWith('http://') || value.startsWith('https://');

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isUrl
                  ? AppTheme.accentBlue.withValues(alpha: 0.4)
                  : AppTheme.borderColor,
            ),
          ),
          child: Row(
            children: [
              Text(isUrl ? '🔗' : '📦', style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded,
                    color: AppTheme.textMuted, size: 18),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Empty tab ─────────────────────────────────────────────────────────────────

class _EmptyTab extends StatelessWidget {
  final IconData icon;
  final String message;
  final String hint;
  const _EmptyTab(
      {required this.icon, required this.message, required this.hint});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: AppTheme.textMuted, size: 48),
              const SizedBox(height: 14),
              Text(message,
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
            ],
          ),
        ),
      );
}

// ── Toggle row ────────────────────────────────────────────────────────────────

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow(
      {required this.icon,
      required this.label,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SwitchListTile(
          secondary: Icon(icon, color: AppTheme.accentAmber, size: 20),
          title: Text(label,
              style:
                  const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
          value: value,
          onChanged: onChanged,
          activeColor: AppTheme.accentAmber,
          contentPadding: EdgeInsets.zero,
        ),
      );
}
