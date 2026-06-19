import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../services/huggingface_service.dart';

class HuggingFaceScreen extends StatefulWidget {
  const HuggingFaceScreen({super.key});

  @override
  State<HuggingFaceScreen> createState() => _HuggingFaceScreenState();
}

class _HuggingFaceScreenState extends State<HuggingFaceScreen> {
  final _hf = HuggingFaceService();
  final _searchCtrl = TextEditingController();

  List<HFModel> _models = [];
  bool _searching = false;
  String? _searchError;

  // Download state
  final Map<String, DownloadProgress> _downloads = {};
  final Map<String, StreamSubscription<DownloadProgress>> _subs = {};

  @override
  void initState() {
    super.initState();
    _search('gguf'); // Default: popular GGUF models
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final s in _subs.values) {
      s.cancel();
    }
    _hf.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = await _hf.searchModels(query);
      if (mounted) setState(() => _models = results);
    } catch (e) {
      if (mounted) setState(() => _searchError = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _openModel(HFModel model) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ModelFilesScreen(
          model: model,
          hf: _hf,
          downloads: _downloads,
          subs: _subs,
          onProgressUpdate: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: const Text('🤗 Hugging Face'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search models (e.g. Qwen, Llama, Phi)...',
                hintStyle:
                    const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                prefixIcon: const Icon(Icons.search,
                    color: AppTheme.textMuted, size: 20),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear,
                            color: AppTheme.textMuted, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _search('gguf');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppTheme.bgSurface,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: AppTheme.accentAmber, width: 1.5),
                ),
              ),
              onSubmitted: _search,
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ),
      body: _searching
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.accentAmber))
          : _searchError != null
              ? _ErrorView(
                  error: _searchError!,
                  onRetry: () => _search(_searchCtrl.text))
              : _models.isEmpty
                  ? const Center(
                      child: Text('No models found',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _models.length,
                      itemBuilder: (_, i) => _ModelCard(
                        model: _models[i],
                        onTap: () => _openModel(_models[i]),
                      ),
                    ),
    );
  }
}

// ── Model card ────────────────────────────────────────────────────────────────

class _ModelCard extends StatelessWidget {
  final HFModel model;
  final VoidCallback onTap;
  const _ModelCard({required this.model, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.name,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    model.author,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _Chip('⬇ ${_fmt(model.downloads)}'),
                      const SizedBox(width: 6),
                      _Chip('❤ ${model.likes}'),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppTheme.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.bgBase,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Text(label,
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      );
}

// ── Model files screen ────────────────────────────────────────────────────────

class _ModelFilesScreen extends StatefulWidget {
  final HFModel model;
  final HuggingFaceService hf;
  final Map<String, DownloadProgress> downloads;
  final Map<String, StreamSubscription<DownloadProgress>> subs;
  final VoidCallback onProgressUpdate;

  const _ModelFilesScreen({
    required this.model,
    required this.hf,
    required this.downloads,
    required this.subs,
    required this.onProgressUpdate,
  });

  @override
  State<_ModelFilesScreen> createState() => _ModelFilesScreenState();
}

class _ModelFilesScreenState extends State<_ModelFilesScreen> {
  List<HFFile>? _files;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final files = await widget.hf.getModelFiles(widget.model.id);
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _download(HFFile file) {
    if (widget.subs.containsKey(file.filename)) return;

    final sub = widget.hf.downloadFile(widget.model.id, file).listen(
      (progress) {
        widget.downloads[file.filename] = progress;
        if (mounted) setState(() {});
        widget.onProgressUpdate();

        if (progress.isDone || progress.hasError) {
          widget.subs.remove(file.filename);
        }
      },
    );
    widget.subs[file.filename] = sub;
    setState(() {});
  }

  void _loadModel(String path, BuildContext ctx) {
    final provider = ctx.read<ChatProvider>();
    provider.loadModel(path).then((_) {
      if (ctx.mounted) {
        Navigator.popUntil(ctx, (r) => r.isFirst);
        Navigator.pushNamed(ctx, '/chat');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.model.name,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            Text(widget.model.author,
                style:
                    const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          ],
        ),
      ),
      body: _error != null
          ? _ErrorView(error: _error!, onRetry: _load)
          : _files == null
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.accentAmber))
              : _files!.isEmpty
                  ? const Center(
                      child: Text('No GGUF files found',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        const _SectionLabel('GGUF Files'),
                        ..._files!.map((f) => _FileCard(
                              file: f,
                              progress: widget.downloads[f.filename],
                              isDownloading:
                                  widget.subs.containsKey(f.filename),
                              onDownload: () => _download(f),
                              onLoad: (path) => _loadModel(path, context),
                              hf: widget.hf,
                            )),
                      ],
                    ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.accentAmber,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );
}

// ── File card ─────────────────────────────────────────────────────────────────

class _FileCard extends StatefulWidget {
  final HFFile file;
  final DownloadProgress? progress;
  final bool isDownloading;
  final VoidCallback onDownload;
  final void Function(String) onLoad;
  final HuggingFaceService hf;

  const _FileCard({
    required this.file,
    required this.progress,
    required this.isDownloading,
    required this.onDownload,
    required this.onLoad,
    required this.hf,
  });

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard> {
  bool _localExists = false;
  String? _localPath;

  @override
  void initState() {
    super.initState();
    _checkLocal();
  }

  @override
  void didUpdateWidget(_FileCard old) {
    super.didUpdateWidget(old);
    if (widget.progress?.isDone == true) _checkLocal();
  }

  Future<void> _checkLocal() async {
    final locals = await widget.hf.localModels();
    final match =
        locals.where((p) => p.endsWith(widget.file.filename)).toList();
    if (mounted) {
      setState(() {
        _localExists = match.isNotEmpty;
        _localPath = match.isNotEmpty ? match.first : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final prog = widget.progress;
    final isDone = prog?.isDone == true || _localExists;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone
              ? AppTheme.accentGreen.withValues(alpha: 0.3)
              : AppTheme.borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.file.filename,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (widget.file.quantLabel.isNotEmpty) ...[
                          _Chip(widget.file.quantLabel),
                          const SizedBox(width: 6),
                        ],
                        _Chip(widget.file.sizeLabel),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                isDone: isDone,
                isDownloading: widget.isDownloading,
                hasError: prog?.hasError == true,
                onDownload: widget.onDownload,
                onLoad: _localPath != null
                    ? () => widget.onLoad(_localPath!)
                    : null,
              ),
            ],
          ),
          // Progress bar
          if (widget.isDownloading && prog != null && !isDone) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: prog.fraction,
                backgroundColor: AppTheme.borderColor,
                valueColor: const AlwaysStoppedAnimation(AppTheme.accentAmber),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtBytes(prog.received)} / ${_fmtBytes(prog.total)}'
              '  (${(prog.fraction * 100).toStringAsFixed(1)}%)',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ],
          if (prog?.hasError == true) ...[
            const SizedBox(height: 6),
            Text('Error: ${prog!.error}',
                style:
                    const TextStyle(color: AppTheme.accentRed, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  String _fmtBytes(int b) {
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _ActionButton extends StatelessWidget {
  final bool isDone;
  final bool isDownloading;
  final bool hasError;
  final VoidCallback onDownload;
  final VoidCallback? onLoad;

  const _ActionButton({
    required this.isDone,
    required this.isDownloading,
    required this.hasError,
    required this.onDownload,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    if (isDownloading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: AppTheme.accentAmber),
      );
    }
    if (isDone && onLoad != null) {
      return ElevatedButton(
        onPressed: onLoad,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accentGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Text('Load',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );
    }
    return IconButton(
      onPressed: onDownload,
      icon: Icon(
        hasError ? Icons.refresh_rounded : Icons.download_rounded,
        color: hasError ? AppTheme.accentRed : AppTheme.accentAmber,
        size: 22,
      ),
      tooltip: hasError ? 'Retry' : 'Download',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  color: AppTheme.accentRed, size: 40),
              const SizedBox(height: 12),
              Text(error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentAmber,
                    foregroundColor: Colors.black),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
}
