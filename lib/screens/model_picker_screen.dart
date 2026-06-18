import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

class ModelPickerScreen extends StatelessWidget {
  const ModelPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          backgroundColor: AppTheme.bgBase,
          appBar: AppBar(title: const Text('🦙 LlamaDart')),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusCard(provider: provider),
                const SizedBox(height: 24),
                _PickerButton(provider: provider),
                const SizedBox(height: 12),
                if (provider.llama.isReady)
                  _StartChatButton(provider: provider),
                const Spacer(),
                const _HintBox(),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Status card ───────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final ChatProvider provider;
  const _StatusCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final filePath = provider.llama.loadedPath;
    final bool isLoading = provider.isLoadingModel;
    final bool isReady = provider.llama.isReady;
    final bool hasError = provider.llama.errorMessage != null;

    // Initialize with defaults — avoids "not assigned" errors
    Color color = AppTheme.textMuted;
    IconData icon = Icons.memory_outlined;
    String title = 'No model loaded';
    String subtitle = 'Pick a .gguf file to get started';

    if (isLoading) {
      color = AppTheme.accentAmber;
      icon = Icons.hourglass_top_rounded;
      title = 'Loading model...';
      subtitle = 'This may take a moment';
    } else if (isReady) {
      color = AppTheme.accentGreen;
      icon = Icons.check_circle_outline_rounded;
      title = 'Model ready';
      subtitle = filePath != null ? p.basename(filePath) : '';
    } else if (hasError) {
      color = AppTheme.accentRed;
      icon = Icons.error_outline_rounded;
      title = 'Load failed';
      subtitle = provider.llama.errorMessage ?? 'Unknown error';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: isLoading
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: color),
                  )
                : Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (isReady)
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

// ── Picker button ─────────────────────────────────────────────────────────────

class _PickerButton extends StatelessWidget {
  final ChatProvider provider;
  const _PickerButton({required this.provider});

  Future<void> _pick(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gguf'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    if (!context.mounted) return;

    await context.read<ChatProvider>().loadModel(path);
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = provider.isLoadingModel;

    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : () => _pick(context),
        icon: const Icon(Icons.folder_open_rounded),
        label: Text(
          provider.llama.isReady ? 'Load different model' : 'Pick GGUF file',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accentAmber,
          foregroundColor: Colors.black,
          disabledBackgroundColor: AppTheme.textMuted,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}

// ── Start chat button ─────────────────────────────────────────────────────────

class _StartChatButton extends StatelessWidget {
  final ChatProvider provider;
  const _StartChatButton({required this.provider});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.pushNamed(context, '/chat'),
        icon: const Icon(Icons.chat_bubble_outline_rounded,
            color: AppTheme.accentGreen),
        label: const Text(
          'Start chatting',
          style: TextStyle(
              color: AppTheme.accentGreen,
              fontSize: 15,
              fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: AppTheme.accentGreen, width: 1.5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}

// ── Hint box ──────────────────────────────────────────────────────────────────

class _HintBox extends StatelessWidget {
  const _HintBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('💡 Where to get GGUF models',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          Text(
            '• huggingface.co → search any model → Files tab → .gguf\n'
            '• Recommended for phone: Q4_K_M quantization\n'
            '• Good starters: Qwen2.5-1.5B, Phi-3-mini, Llama-3.2-3B',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 12, height: 1.6),
          ),
        ],
      ),
    );
  }
}
