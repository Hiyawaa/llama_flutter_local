import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../services/llama_service.dart' show ModelStatus;
import '../services/huggingface_service.dart';
import '../services/ram_guard_service.dart';
import '../services/model_loader_service.dart';
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

  Future<void> _scanLocalModels() async {
    setState(() => _loadingModels = true);
    final found = <_LocalModel>[];

    try {
      // 1. HF downloads: app documents/models/
      final hf = HuggingFaceService();
      final hfPaths = await hf.localModels();
      hf.dispose();
      for (final path in hfPaths) {
        final file = File(path);
        final size = await file.length();
        found.add(_LocalModel(
          path: path,
          size: size,
          source: 'Downloaded',
          format: ModelFormat.gguf,
        ));
      }

      // 2. App documents root
      final docsDir = await getApplicationDocumentsDirectory();
      await _scanDir(docsDir.path, found, skip: p.join(docsDir.path, 'models'));

      // 3. External storage (Android)
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

    await _annotateLoadability(deduped);

    if (mounted) {
      setState(() {
        _localModels = deduped;
        _loadingModels = false;
      });
    }
  }

  Future<void> _scanDir(
    String dirPath,
    List<_LocalModel> out, {
    String? skip,
  }) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      await for (final e in dir.list(recursive: false)) {
        if (skip != null && e.path == skip) continue;
        final name = p.basename(e.path).toLowerCase();
        if (e is File && name.endsWith('.gguf') && !name.contains('mmproj')) {
          final size = await e.length();
          out.add(_LocalModel(
            path: e.path,
            size: size,
            source: 'Local',
            format: ModelFormat.gguf,
          ));
        } else if (e is File && name.endsWith('.litertlm')) {
          // Feature 2: detected, but not runnable yet — see
          // model_loader_service.dart. Still surfaced in the list (greyed
          // out) rather than hidden, so the user knows the app saw the
          // file and why it can't be loaded.
          final size = await e.length();
          out.add(_LocalModel(
            path: e.path,
            size: size,
            source: 'Local',
            format: ModelFormat.liteRtLm,
          ));
        }
      }
    } catch (_) {}
  }

  /// Feature 2/RAM-guardrail integration: after scanning, check each
  /// candidate model against RamGuard so unloadable ones can be greyed
  /// out in the UI up front instead of letting the user tap "Load" and
  /// hit a rejection (or worse, an OOM) after the fact.
  Future<void> _annotateLoadability(List<_LocalModel> models) async {
    if (!mounted) return;
    final contextSize = context.read<ChatProvider>().contextSize;
    for (final m in models) {
      if (m.format != ModelFormat.gguf) {
        m.ramOk = false; // litertlm: not runnable regardless of RAM yet
        continue;
      }
      final estimateMb = RamGuard.estimateModelLoadMb(
        fileSizeBytes: m.size,
        contextSize: contextSize,
      );
      m.ramOk = await RamGuard.canLoad(estimateMb, failOpen: true);
    }
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
                _ImageScannerButton(),
                const SizedBox(height: 10),

                if (provider.llama.isReady) ...[
                  _StartChatButton(provider: provider),
                  const SizedBox(height: 10),
                ],

                const SizedBox(height: 14),

                // ── Downloaded models ─────────────────────────────────────
                Row(
                  children: [
                    const Text(
                      'DOWNLOADED MODELS',
                      style: TextStyle(
                        color: AppTheme.accentAmber,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_loadingModels)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppTheme.accentAmber,
                        ),
                      )
                    else
                      Text(
                        '${_localModels.length}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    const Spacer(),
                    if (!_loadingModels && _localModels.isEmpty)
                      const Text(
                        'Pull down to refresh',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                if (!_loadingModels && _localModels.isEmpty)
                  const _EmptyModels()
                else
                  ..._localModels.map(
                    (m) => _LocalModelCard(
                      model: m,
                      provider: provider,
                      isLoaded: provider.llama.loadedPath == m.path,
                      isEmbedder: provider.embeddingModelPath == m.path,
                      onLoad: () async {
                        await provider.loadModel(m.path);
                        if (context.mounted &&
                            provider.llama.status == ModelStatus.ready) {
                          Navigator.pushNamed(context, '/chat');
                        }
                      },
                      onSetEmbedder: () {
                        provider.setEmbeddingModelPath(m.path);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content:
                                  Text('${m.name} set as RAG embedding model')),
                        );
                      },
                      onDelete: () => _confirmDelete(context, m),
                    ),
                  ),

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
        title: const Text(
          'Delete model?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'This will permanently delete\n${p.basename(model.path)}',
          style: const TextStyle(color: AppTheme.textSecondary),
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
              'Delete',
              style: TextStyle(color: AppTheme.accentRed),
            ),
          ),
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

// ── Data model ────────────────────────────────────────────────────────────────

class _LocalModel {
  final String path;
  final int size;
  final String source;
  final ModelFormat format;
  // Mutable: filled in asynchronously by _annotateLoadability after the
  // initial scan, since RamGuard reads live device memory and shouldn't
  // block the (fast) file-listing part of the scan.
  bool ramOk = true;

  _LocalModel({
    required this.path,
    required this.size,
    required this.source,
    this.format = ModelFormat.gguf,
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
      'F32',
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
  final bool isEmbedder;
  final VoidCallback onLoad;
  final VoidCallback onSetEmbedder;
  final VoidCallback onDelete;

  const _LocalModelCard({
    required this.model,
    required this.provider,
    required this.isLoaded,
    required this.isEmbedder,
    required this.onLoad,
    required this.onSetEmbedder,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = !model.ramOk;
    final isLiteRt = model.format == ModelFormat.liteRtLm;

    return Opacity(
      opacity: blocked ? 0.55 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isEmbedder
                ? AppTheme.accentBlue.withValues(alpha: 0.5)
                : isLoaded
                    ? AppTheme.accentGreen.withValues(alpha: 0.4)
                    : blocked
                        ? AppTheme.accentRed.withValues(alpha: 0.3)
                        : AppTheme.borderColor,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color:
                      (isLoaded ? AppTheme.accentGreen : AppTheme.accentAmber)
                          .withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        (isLoaded ? AppTheme.accentGreen : AppTheme.accentAmber)
                            .withValues(alpha: 0.3),
                  ),
                ),
                child: Center(
                  child: Text(
                    isLoaded ? '✅' : (blocked ? '🚫' : '🤖'),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Name + chips
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        _Chip(model.sizeLabel, color: AppTheme.accentAmber),
                        if (model.quantLabel.isNotEmpty)
                          _Chip(model.quantLabel, color: AppTheme.accentBlue),
                        _Chip(model.source, color: AppTheme.textMuted),
                        if (isEmbedder)
                          _Chip('Embedder ✓', color: AppTheme.accentBlue),
                        if (blocked)
                          _Chip(
                            isLiteRt ? 'Not supported yet' : 'Not enough RAM',
                            color: AppTheme.accentRed,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // Actions
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
                          onPressed: (provider.isLoadingModel || blocked)
                              ? null
                              : onLoad,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: blocked
                                ? AppTheme.borderColor
                                : AppTheme.accentAmber,
                            foregroundColor:
                                blocked ? AppTheme.textMuted : Colors.black,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: provider.isLoadingModel
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : Text(
                                  blocked ? 'Blocked' : 'Load',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
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
                              borderRadius: BorderRadius.circular(8),
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Chat →',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: onSetEmbedder,
                          child: Tooltip(
                            message: isEmbedder
                                ? 'Current RAG embedding model'
                                : 'Use for RAG embeddings',
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                isEmbedder
                                    ? Icons.data_object_rounded
                                    : Icons.data_object_outlined,
                                color: isEmbedder
                                    ? AppTheme.accentBlue
                                    : AppTheme.textMuted,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: onDelete,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              color: AppTheme.textMuted,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

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
        child: Text(
          label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600),
        ),
      );
}

class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) => Container(
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
            Text(
              'No GGUF files found',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Download models from Hugging Face\nor place .gguf files in your Downloads folder',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
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
          label: const Text(
            'Browse Hugging Face',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentAmber,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
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
          label: const Text(
            'Vision Chat',
            style: TextStyle(
              color: AppTheme.accentGreen,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentGreen, width: 1.5),
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
          icon: const Icon(
            Icons.chat_bubble_outline_rounded,
            color: AppTheme.accentGreen,
          ),
          label: const Text(
            'Continue chatting',
            style: TextStyle(
              color: AppTheme.accentGreen,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
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
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (status == ModelStatus.ready)
            IconButton(
              icon: const Icon(
                Icons.close,
                color: AppTheme.textMuted,
                size: 18,
              ),
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

  static const _recommendations = [
    _Recommendation(
      name: 'Qwen2.5-Math-1.5B',
      note: 'best for math',
      size: '~1 GB',
    ),
    _Recommendation(
      name: 'Phi-3-mini-Q4_K_M',
      note: 'fast & smart',
      size: '~2.3 GB',
    ),
    _Recommendation(
      name: 'Llama-3.2-3B-Q4_K_M',
      note: 'great all-rounder',
      size: '~2 GB',
    ),
    // ── Vision-language models (VLM) ──────────────────────────────────
    // These need TWO files to work: the main gguf plus a matching mmproj
    // gguf (the vision projector/encoder weights). We don't need to
    // search for the mmproj separately — HuggingFaceScreen's
    // _ModelFilesScreen already lists every file in a repo (including
    // mmproj, in its own "Vision file (required for images)" section with
    // a banner) once the person opens the repo that this search lands on.
    // mmprojName/mmprojSize here are just for display on this tile.
    _Recommendation(
      name: 'Qwen2-VL-2B-Instruct',
      note: 'vision + text, compact',
      size: '~1.5 GB',
      isVLM: true,
      mmprojName: 'mmproj-Qwen2-VL-2B',
      mmprojSize: '~600 MB',
    ),
    _Recommendation(
      name: 'LLaVA-Phi-3-mini',
      note: 'vision + text, fast',
      size: '~2.4 GB',
      isVLM: true,
      mmprojName: 'mmproj-LLaVA-Phi-3-mini',
      mmprojSize: '~600 MB',
    ),
  ];

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '💡 Recommended for Android',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ..._recommendations.map(
              (r) => _RecommendationTile(recommendation: r),
            ),
            const SizedBox(height: 4),
            const Text(
              'Q4_K_M = best speed/quality balance',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
      );
}

class _Recommendation {
  final String name;
  final String note;
  final String size;
  final bool isVLM;
  final String? mmprojName;
  final String? mmprojSize;

  const _Recommendation({
    required this.name,
    required this.note,
    required this.size,
    this.isVLM = false,
    this.mmprojName,
    this.mmprojSize,
  });
}

class _RecommendationTile extends StatelessWidget {
  final _Recommendation recommendation;
  const _RecommendationTile({required this.recommendation});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.bgBase,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => HuggingFaceScreen(
                initialQuery: recommendation.name,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              recommendation.name,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (recommendation.isVLM) ...[
                            const SizedBox(width: 6),
                            _VLMBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${recommendation.note} · ${recommendation.size}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      if (recommendation.mmprojName != null) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(
                              Icons.visibility_rounded,
                              size: 11,
                              color: AppTheme.accentBlue,
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                '+ ${recommendation.mmprojName} (${recommendation.mmprojSize})',
                                style: const TextStyle(
                                  color: AppTheme.accentBlue,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VLMBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppTheme.accentBlue.withAlpha(30),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppTheme.accentBlue.withAlpha(90)),
        ),
        child: const Text(
          'VLM',
          style: TextStyle(
            color: AppTheme.accentBlue,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}
