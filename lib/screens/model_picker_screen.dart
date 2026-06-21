import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../services/llama_service.dart' show ModelStatus;
import '../services/huggingface_service.dart';
import 'huggingface_screen.dart';

class ModelPickerScreen extends StatefulWidget {
  const ModelPickerScreen({super.key});

  @override
  State<ModelPickerScreen> createState() => _ModelPickerScreenState();
}

class _ModelPickerScreenState extends State<ModelPickerScreen> {
  List<_LocalModel> _localModels = [];
  bool _loadingModels = false;

  @override
  void initState() {
    super.initState();
    _scanLocalModels();
  }

  /// Scan both the HF downloads folder and the user's Downloads folder
  Future<void> _scanLocalModels() async {
    setState(() => _loadingModels = true);
    final found = <_LocalModel>[];

    try {
      // 1. HF downloads: app documents/models/
      final hf = HuggingFaceService();
      final hfPaths = await hf.localModels();
      hf.dispose();
      final hfDirSeen = <String>{};
      for (final path in hfPaths) {
        if (_isMmprojFile(path)) continue;
        final file = File(path);
        final size = await file.length();
        final dir = p.dirname(path);
        hfDirSeen.add(dir);
        found.add(_LocalModel(
          path: path,
          size: size,
          source: 'Downloaded',
          isVision: await _hasSiblingMmproj(dir),
        ));
      }

      // 2. App documents root (user may have placed files here)
      final docsDir = await getApplicationDocumentsDirectory();
      await _scanDir(docsDir.path, found, skip: p.join(docsDir.path, 'models'));

      // 3. External storage / Downloads (Android)
      final extDirs = await getExternalStorageDirectories();
      if (extDirs != null) {
        for (final dir in extDirs) {
          await _scanDir(dir.path, found);
        }
      }

      // 4. Common Android Download folders
      for (final dl in [
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
      ]) {
        await _scanDir(dl, found);
      }
    } catch (_) {}

    // Deduplicate by path
    final seen = <String>{};
    final deduped = found.where((m) => seen.add(m.path)).toList();
    deduped.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    if (mounted) {
      setState(() {
        _localModels = deduped;
        _loadingModels = false;
      });
    }
  }

  bool _isMmprojFile(String path) =>
      p.basename(path).toLowerCase().contains('mmproj');

  /// True if [dirPath] contains a file with "mmproj" in its name — meaning
  /// any main model GGUF in that same folder can do vision.
  Future<bool> _hasSiblingMmproj(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return false;
      await for (final e in dir.list(recursive: false)) {
        if (e is File && _isMmprojFile(e.path)) return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _scanDir(String dirPath, List<_LocalModel> out,
      {String? skip}) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final hasVisionSibling = await _hasSiblingMmproj(dirPath);
      await for (final e in dir.list(recursive: false)) {
        if (skip != null && e.path == skip) continue;
        if (e is File &&
            e.path.toLowerCase().endsWith('.gguf') &&
            !_isMmprojFile(e.path)) {
          final size = await e.length();
          out.add(_LocalModel(
            path: e.path,
            size: size,
            source: 'Local',
            isVision: hasVisionSibling,
          ));
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          backgroundColor: AppTheme.bgBase,
          appBar: AppBar(
            title: const Text('🦙 LlamaDart'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh model list',
                onPressed: _scanLocalModels,
              ),
            ],
          ),
          body: RefreshIndicator(
            color: AppTheme.accentAmber,
            onRefresh: _scanLocalModels,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Status ────────────────────────────────────────────────
                _StatusCard(provider: provider),
                const SizedBox(height: 20),

                // ── Action buttons ────────────────────────────────────────
                _HuggingFaceButton(),
                const SizedBox(height: 10),

                if (provider.llama.isReady)
                  _StartChatButton(provider: provider),

                const SizedBox(height: 24),

                // ── Downloaded models ─────────────────────────────────────
                Row(
                  children: [
                    const Text('Downloaded Models',
                        style: TextStyle(
                            color: AppTheme.accentAmber,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2)),
                    const SizedBox(width: 8),
                    if (_loadingModels)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: AppTheme.accentAmber),
                      )
                    else
                      Text('${_localModels.length}',
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 11)),
                    const Spacer(),
                    if (!_loadingModels && _localModels.isEmpty)
                      const Text('Pull down to refresh',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 10),

                if (!_loadingModels && _localModels.isEmpty)
                  _EmptyModels()
                else
                  ..._localModels.map((m) => _LocalModelCard(
                        model: m,
                        provider: provider,
                        isLoaded: provider.llama.loadedPath == m.path,
                        onLoad: () async {
                          await provider.loadModel(m.path);
                          if (context.mounted &&
                              provider.llama.status == ModelStatus.ready) {
                            Navigator.pushNamed(context, '/chat');
                          }
                        },
                        onDelete: () async {
                          await _confirmDelete(context, m);
                        },
                      )),

                const SizedBox(height: 24),
                const _VisionModelsSection(),

                const SizedBox(height: 24),
                const _HintBox(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, _LocalModel model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgSurface,
        title: const Text('Delete model?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'This will permanently delete\n${p.basename(model.path)}',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppTheme.accentRed))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(model.path).delete();
    } catch (_) {}
    await _scanLocalModels();
  }
}

// ── Data class ────────────────────────────────────────────────────────────────

class _LocalModel {
  final String path;
  final int size;
  final String source;
  final bool isVision;
  _LocalModel({
    required this.path,
    required this.size,
    required this.source,
    this.isVision = false,
  });

  String get name => p.basename(path);

  String get sizeLabel {
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get quantLabel {
    final n = name.toUpperCase();
    for (final q in [
      'Q8_0',
      'Q6_K',
      'Q5_K_M',
      'Q5_K_S',
      'Q5_0',
      'Q4_K_M',
      'Q4_K_S',
      'Q4_0',
      'Q3_K_M',
      'Q2_K',
      'IQ4_XS',
      'F16',
      'F32'
    ]) {
      if (n.contains(q)) return q;
    }
    return '';
  }
}

// ── Local model card ──────────────────────────────────────────────────────────

class _LocalModelCard extends StatelessWidget {
  final _LocalModel model;
  final ChatProvider provider;
  final bool isLoaded;
  final VoidCallback onLoad;
  final VoidCallback onDelete;

  const _LocalModelCard({
    required this.model,
    required this.provider,
    required this.isLoaded,
    required this.onLoad,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLoaded
              ? AppTheme.accentGreen.withValues(alpha: 0.4)
              : AppTheme.borderColor,
        ),
      ),
      child: Column(
        children: [
          // Main row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                // Model icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color:
                        (isLoaded ? AppTheme.accentGreen : AppTheme.accentAmber)
                            .withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (isLoaded
                              ? AppTheme.accentGreen
                              : AppTheme.accentAmber)
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      isLoaded ? '✅' : '🤖',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Name + meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.name,
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          _Chip(model.sizeLabel, color: AppTheme.accentAmber),
                          if (model.quantLabel.isNotEmpty)
                            _Chip(model.quantLabel, color: AppTheme.accentBlue),
                          _Chip(model.source, color: AppTheme.textMuted),
                          if (model.isVision)
                            const _Chip('👁 Vision',
                                color: AppTheme.accentGreen),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Actions — fixed width so the row never overflows on the
                // right regardless of model name/chip length.
                SizedBox(
                  width: 64,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isLoaded)
                        SizedBox(
                          width: double.infinity,
                          height: 34,
                          child: ElevatedButton(
                            onPressed: provider.isLoadingModel ? null : onLoad,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentAmber,
                              foregroundColor: Colors.black,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: provider.isLoadingModel
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.black))
                                : const Text('Load',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700)),
                          ),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          height: 34,
                          child: ElevatedButton(
                            onPressed: () =>
                                Navigator.pushNamed(context, '/chat'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentGreen,
                              foregroundColor: Colors.black,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Chat →',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ),
                      const SizedBox(height: 4),
                      // Delete
                      GestureDetector(
                        onTap: onDelete,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.delete_outline_rounded,
                              color: AppTheme.textMuted, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyModels extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: const Column(
        children: [
          Text('📂', style: TextStyle(fontSize: 32)),
          SizedBox(height: 8),
          Text('No GGUF files found',
              style: TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text(
            'Download models from Hugging Face\nor place .gguf files in your Downloads folder',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ── Recommended vision models ─────────────────────────────────────────────────

class _VisionModel {
  final String label;
  final String note;
  final String hfModelId;
  final String ggufFile;
  final String mmprojFile;
  const _VisionModel({
    required this.label,
    required this.note,
    required this.hfModelId,
    required this.ggufFile,
    required this.mmprojFile,
  });
}

class _VisionModelsSection extends StatelessWidget {
  const _VisionModelsSection();

  static const _models = [
    _VisionModel(
      label: 'Qwen2-VL-2B',
      note: 'Recommended',
      hfModelId: 'Qwen2-VL',
      ggufFile: 'Qwen2-VL-2B-Instruct-Q4_0.gguf',
      mmprojFile: 'Qwen2-VL-2B-Instruct-mmproj-f16.gguf',
    ),
    _VisionModel(
      label: 'MiniCPM-V-2.6',
      note: '',
      hfModelId: 'MiniCPM',
      ggufFile: 'MiniCPM-V-2_6-int4.gguf',
      mmprojFile: 'MiniCPM-V-2_6-mmproj-bf16.gguf',
    ),
    _VisionModel(
      label: 'Moondream2',
      note: 'Lightest',
      hfModelId: 'vikhyatk/moondream2',
      ggufFile: 'moondream2-text-model-f16.gguf',
      mmprojFile: 'moondream2-mmproj-f16.gguf',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Text('👁 VISION MODELS',
                style: TextStyle(
                    color: AppTheme.accentGreen,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Needed for the Image Scanner — each model needs TWO files '
          '(model + mmproj). Tap to open the matching download page.',
          style:
              TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        ..._models.map((m) => _VisionModelCard(model: m)),
      ],
    );
  }
}

class _VisionModelCard extends StatelessWidget {
  final _VisionModel model;
  const _VisionModelCard({required this.model});

  void _open(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HuggingFaceScreen(initialQuery: model.hfModelId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _open(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.accentGreen.withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppTheme.accentGreen.withValues(alpha: 0.3)),
              ),
              child: const Center(
                  child: Text('👁', style: TextStyle(fontSize: 16))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(model.label,
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      if (model.note.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _Chip(model.note, color: AppTheme.accentGreen),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${model.ggufFile} + mmproj',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 10.5),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip(this.label, {required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w600)),
      );
}

class _ImageScannerButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
        child: OutlinedButton.icon(
          onPressed: () => Navigator.pushNamed(context, '/image-scanner'),
          icon: const Icon(Icons.image_search_rounded,
              color: AppTheme.accentGreen),
          label: const Text('Image Scanner',
              style: TextStyle(
                  color: AppTheme.accentGreen,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentGreen, width: 1.5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      );
}

class _HuggingFaceButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: () => Navigator.pushNamed(context, '/huggingface'),
          icon: const Text('🤗', style: TextStyle(fontSize: 18)),
          label: const Text('Browse Hugging Face',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentAmber,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      );
}

class _StartChatButton extends StatelessWidget {
  final ChatProvider provider;
  const _StartChatButton({required this.provider});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: OutlinedButton.icon(
          onPressed: () => Navigator.pushNamed(context, '/chat'),
          icon: const Icon(Icons.chat_bubble_outline_rounded,
              color: AppTheme.accentGreen),
          label: const Text('Continue chatting',
              style: TextStyle(
                  color: AppTheme.accentGreen,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentGreen, width: 1.5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      );
}

class _StatusCard extends StatelessWidget {
  final ChatProvider provider;
  const _StatusCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final status = provider.llama.status;
    final filePath = provider.llama.loadedPath;

    Color color = AppTheme.textMuted;
    IconData icon = Icons.memory_outlined;
    String title = 'No model loaded';
    String subtitle = 'Pick a model below to get started';

    if (status == ModelStatus.loading) {
      color = AppTheme.accentAmber;
      icon = Icons.hourglass_top_rounded;
      title = 'Loading model...';
      subtitle = 'This may take a moment';
    } else if (status == ModelStatus.ready) {
      color = AppTheme.accentGreen;
      icon = Icons.check_circle_outline_rounded;
      title = 'Model ready';
      subtitle = filePath != null ? p.basename(filePath) : '';
    } else if (status == ModelStatus.error) {
      color = AppTheme.accentRed;
      icon = Icons.error_outline_rounded;
      title = 'Load failed';
      subtitle = provider.llama.errorMessage ?? 'Unknown error';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: status == ModelStatus.loading
                ? Padding(
                    padding: const EdgeInsets.all(11),
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: color),
                  )
                : Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: color,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    if (status == ModelStatus.ready &&
                        provider.isVisionCapable) ...[
                      const SizedBox(width: 6),
                      const _Chip('👁 Vision', color: AppTheme.accentGreen),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (status == ModelStatus.ready)
            IconButton(
              icon:
                  const Icon(Icons.close, color: AppTheme.textMuted, size: 18),
              tooltip: 'Unload model',
              onPressed: provider.unloadModel,
            ),
        ],
      ),
    );
  }
}

class _HintBox extends StatelessWidget {
  const _HintBox();

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
            Text('💡 Recommended for Android',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              '• Qwen2.5-Math-1.5B — best for math (~1 GB)\n'
              '• Phi-3-mini-Q4_K_M — fast & smart (~2.3 GB)\n'
              '• Llama-3.2-3B-Q4_K_M — great all-rounder (~2 GB)\n'
              '• Q4_K_M = best speed/quality balance',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      );
}
