import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:background_downloader/background_downloader.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../services/huggingface_service.dart';
import '../services/download_service.dart';

// ── Per-file download state ───────────────────────────────────────────────────

class _DlState {
  double progress = 0;
  TaskStatus status = TaskStatus.enqueued;
  bool done = false;
  String? error;

  bool get isRunning =>
      status == TaskStatus.running || status == TaskStatus.enqueued;
  bool get isPaused => status == TaskStatus.paused;
  bool get isFailed => status == TaskStatus.failed || error != null;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class HuggingFaceScreen extends StatefulWidget {
  final String? initialQuery;
  const HuggingFaceScreen({super.key, this.initialQuery});

  @override
  State<HuggingFaceScreen> createState() => _HuggingFaceScreenState();
}

class _HuggingFaceScreenState extends State<HuggingFaceScreen> {
  final _hf = HuggingFaceService();
  final _searchCtrl = TextEditingController();

  List<HFModel> _models = [];
  bool _searching = false;
  String? _searchError;

  // filename → download state
  final Map<String, _DlState> _downloads = {};

  @override
  void initState() {
    super.initState();
    DownloadService.init();
    final query = widget.initialQuery;
    if (query != null && query.isNotEmpty) {
      _searchCtrl.text = query;
    }
    _search(query?.isNotEmpty == true ? query! : 'gguf');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                        color: AppTheme.accentAmber, width: 1.5)),
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

  void _openModel(HFModel model) {
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _ModelFilesScreen(
            model: model,
            hf: _hf,
            downloads: _downloads,
            onUpdate: () {
              if (mounted) setState(() {});
            },
          ),
        ));
  }
}

// ── Model list card ───────────────────────────────────────────────────────────

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
                  Text(model.name,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(model.author,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(children: [
                    _Tag('⬇ ${_fmt(model.downloads)}'),
                    const SizedBox(width: 6),
                    _Tag('❤ ${model.likes}'),
                  ]),
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

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);
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
  final Map<String, _DlState> downloads;
  final VoidCallback onUpdate;

  const _ModelFilesScreen({
    required this.model,
    required this.hf,
    required this.downloads,
    required this.onUpdate,
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
    _checkExisting();
  }

  Future<void> _load() async {
    try {
      final files = await widget.hf.getModelFiles(widget.model.id);
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Pre-mark any already-downloaded files as done
  Future<void> _checkExisting() async {
    final local = await DownloadService.listDownloaded();
    for (final path in local) {
      final name = path.split('/').last;
      if (!widget.downloads.containsKey(name)) {
        final ds = _DlState();
        ds.done = true;
        ds.progress = 1.0;
        ds.status = TaskStatus.complete;
        widget.downloads[name] = ds;
      }
    }
    if (mounted) setState(() {});
  }

  void _startDownload(HFFile file) {
    final url =
        'https://huggingface.co/${widget.model.id}/resolve/main/${file.rfilename}';

    final ds = _DlState();
    setState(() => widget.downloads[file.filename] = ds);

    // Fire-and-forget — background_downloader keeps it alive
    DownloadService.startDownload(
      url,
      file.filename,
      onProgress: (p) {
        ds.progress = p;
        ds.status = TaskStatus.running;
        if (mounted) setState(() {});
        widget.onUpdate();
      },
      onStatus: (status) {
        ds.status = status;
        if (status == TaskStatus.complete) {
          ds.done = true;
          ds.progress = 1.0;
          ds.error = null;
        } else if (status == TaskStatus.failed) {
          ds.error = 'Download failed — tap retry';
        } else if (status == TaskStatus.canceled) {
          widget.downloads.remove(file.filename);
        }
        if (mounted) setState(() {});
        widget.onUpdate();
      },
    );
  }

  void _cancel(HFFile file) {
    DownloadService.cancel(file.filename);
    setState(() => widget.downloads.remove(file.filename));
  }

  Future<void> _loadModel(String path) async {
    final provider = context.read<ChatProvider>();
    await provider.loadModel(path);
    if (!mounted) return;
    Navigator.popUntil(context, (r) => r.isFirst);
    Navigator.pushNamed(context, '/chat');
  }

  /// Before loading the main model file, check whether this repo has a
  /// vision projector and, if so, whether it's actually been downloaded —
  /// otherwise the model will load as text-only with no warning, which is
  /// exactly the confusing "I loaded Qwen2-VL but the image button stayed
  /// off" situation.
  Future<void> _loadWithVisionCheck(HFFile mainFile) async {
    final files = _files ?? [];
    final mmprojFiles = files.where((f) => f.isMmproj).toList();
    final path = await DownloadService.localPath(mainFile.filename);

    if (mmprojFiles.isEmpty) {
      // No vision variant exists for this repo at all — just a text model.
      await _loadModel(path);
      return;
    }

    final mmprojDownloaded =
        mmprojFiles.any((f) => widget.downloads[f.filename]?.done == true);

    if (mmprojDownloaded) {
      await _loadModel(path);
      return;
    }

    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgSurface,
        title: const Text('Missing vision file',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'This model supports image understanding, but its mmproj file '
          '(${mmprojFiles.first.filename}) hasn\'t been downloaded yet.\n\n'
          "Without it, this will load as a text-only model and the image "
          "scanner won't be available.",
          style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Download mmproj first',
                style: TextStyle(color: AppTheme.accentGreen)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Load anyway (text-only)',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
        ],
      ),
    );
    if (proceed == true) await _loadModel(path);
  }

  @override
  Widget build(BuildContext context) {
    final files = _files ?? [];
    final hasVisionVariant = files.any((f) => f.isMmproj);
    final mainFiles = files.where((f) => !f.isMmproj).toList();
    final mmprojFiles = files.where((f) => f.isMmproj).toList();

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
                        // Active downloads banner
                        if (widget.downloads.values
                            .any((d) => d.isRunning && !d.done))
                          _ActiveDownloadsBanner(),

                        if (hasVisionVariant) const _VisionRequiredBanner(),

                        const _SectionLabel('Model'),
                        ...mainFiles.map((f) => _FileCard(
                              file: f,
                              dl: widget.downloads[f.filename],
                              onDownload: () => _startDownload(f),
                              onCancel: () => _cancel(f),
                              onLoad: () => _loadWithVisionCheck(f),
                            )),

                        if (mmprojFiles.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const _SectionLabel(
                              'Vision file (required for images)'),
                          ...mmprojFiles.map((f) => _FileCard(
                                file: f,
                                dl: widget.downloads[f.filename],
                                isMmproj: true,
                                onDownload: () => _startDownload(f),
                                onCancel: () => _cancel(f),
                                onLoad: () async {
                                  // mmproj files aren't "loaded" on their own —
                                  // they get auto-attached when the main model
                                  // loads. Tapping just confirms it's ready.
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Vision file ready — load the main '
                                          'model above to enable image scanning'),
                                    ),
                                  );
                                },
                              )),
                        ],
                      ],
                    ),
    );
  }
}

class _VisionRequiredBanner extends StatelessWidget {
  const _VisionRequiredBanner();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.accentGreen.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.visibility_rounded,
                color: AppTheme.accentGreen, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'This model supports images — download BOTH the model file '
                'and the vision file below for the image scanner to work.',
                style: TextStyle(
                    color: AppTheme.accentGreen, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

class _ActiveDownloadsBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.accentAmber.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.download_rounded, color: AppTheme.accentAmber, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Download continues in the background — '
                'check the notification bar for progress.',
                style: TextStyle(
                    color: AppTheme.accentAmber, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      );
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

class _FileCard extends StatelessWidget {
  final HFFile file;
  final _DlState? dl;
  final bool isMmproj;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onLoad;

  const _FileCard({
    required this.file,
    required this.dl,
    this.isMmproj = false,
    required this.onDownload,
    required this.onCancel,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = dl?.done == true;
    final running = dl?.isRunning == true && !isDone;
    final failed = dl?.isFailed == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone
              ? AppTheme.accentGreen.withValues(alpha: 0.35)
              : running
                  ? AppTheme.accentAmber.withValues(alpha: 0.35)
                  : isMmproj
                      ? AppTheme.accentGreen.withValues(alpha: 0.25)
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
                    Text(file.filename,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 5, runSpacing: 5, children: [
                      _Tag2(file.sizeLabel, AppTheme.accentAmber),
                      if (file.quantLabel.isNotEmpty)
                        _Tag2(file.quantLabel, AppTheme.accentBlue),
                      if (isMmproj)
                        _Tag2('Required for vision', AppTheme.accentGreen),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ActionBtn(
                isDone: isDone,
                running: running,
                failed: failed,
                onDownload: onDownload,
                onCancel: onCancel,
                onLoad: onLoad,
              ),
            ],
          ),

          // Progress bar
          if (running) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: dl!.progress,
                minHeight: 5,
                backgroundColor: AppTheme.borderColor,
                valueColor: const AlwaysStoppedAnimation(AppTheme.accentAmber),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${(dl!.progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                        color: AppTheme.accentAmber, fontSize: 11)),
                const Text('Downloading...',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
              ],
            ),
          ],

          if (isDone) ...[
            const SizedBox(height: 6),
            const Row(children: [
              Icon(Icons.check_circle_rounded,
                  color: AppTheme.accentGreen, size: 13),
              SizedBox(width: 4),
              Text('Downloaded',
                  style: TextStyle(color: AppTheme.accentGreen, fontSize: 11)),
            ]),
          ],

          if (failed && dl?.error != null) ...[
            const SizedBox(height: 6),
            Text(dl!.error!,
                style:
                    const TextStyle(color: AppTheme.accentRed, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

class _Tag2 extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag2(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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

class _ActionBtn extends StatelessWidget {
  final bool isDone;
  final bool running;
  final bool failed;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onLoad;
  const _ActionBtn({
    required this.isDone,
    required this.running,
    required this.failed,
    required this.onDownload,
    required this.onCancel,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    if (isDone) {
      return ElevatedButton(
        onPressed: onLoad,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accentGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Load',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      );
    }
    if (running) {
      return IconButton(
        icon: const Icon(Icons.cancel_rounded,
            color: AppTheme.accentRed, size: 22),
        tooltip: 'Cancel',
        onPressed: onCancel,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      );
    }
    return IconButton(
      icon: Icon(
        failed ? Icons.refresh_rounded : Icons.download_rounded,
        color: failed ? AppTheme.accentRed : AppTheme.accentAmber,
        size: 22,
      ),
      tooltip: failed ? 'Retry' : 'Download',
      onPressed: onDownload,
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

// _accentBlue was unused and removed.
