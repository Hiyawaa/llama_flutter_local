import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<SavedConversation> _convs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<ChatProvider>();
    final convs = await provider.historyService.loadAll();
    if (mounted) {
      setState(() {
        _convs = convs;
        _loading = false;
      });
    }
  }

  Future<void> _delete(SavedConversation conv) async {
    final provider = context.read<ChatProvider>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgSurface,
        title: const Text('Delete conversation?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('This cannot be undone.',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: AppTheme.accentRed)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await provider.historyService.delete(conv.id);
    if (!mounted) return;
    setState(() => _convs.removeWhere((c) => c.id == conv.id));
  }

  void _open(SavedConversation conv) {
    context.read<ChatProvider>().loadConversation(conv);
    Navigator.popUntil(context, (r) => r.isFirst);
    Navigator.pushNamed(context, '/chat');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: const Text('Chat History'),
        actions: [
          if (_convs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Delete all',
              onPressed: () async {
                final provider = context.read<ChatProvider>();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppTheme.bgSurface,
                    title: const Text('Delete all history?',
                        style: TextStyle(color: AppTheme.textPrimary)),
                    content: const Text(
                        'All saved conversations will be removed.',
                        style: TextStyle(color: AppTheme.textSecondary)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel',
                              style: TextStyle(color: AppTheme.textSecondary))),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete all',
                              style: TextStyle(color: AppTheme.accentRed))),
                    ],
                  ),
                );
                if (ok == true) {
                  if (mounted) {
                    await provider.historyService.deleteAll();
                    if (mounted) {
                      setState(() => _convs.clear());
                    }
                  }
                }
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.accentAmber))
          : _convs.isEmpty
              ? const _EmptyHistory()
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _convs.length,
                  itemBuilder: (_, i) => _ConvCard(
                    conv: _convs[i],
                    onTap: () => _open(_convs[i]),
                    onDelete: () => _delete(_convs[i]),
                  ),
                ),
    );
  }
}

// ── Conversation card ─────────────────────────────────────────────────────────

class _ConvCard extends StatelessWidget {
  final SavedConversation conv;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ConvCard({
    required this.conv,
    required this.onTap,
    required this.onDelete,
  });

  String _timeLabel() {
    final now = DateTime.now();
    final diff = now.difference(conv.createdAt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final d = conv.createdAt;
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    // Get last assistant message as preview
    final assistantMsgs =
        conv.messages.where((m) => m.role == 'assistant').toList();
    final preview = assistantMsgs.isNotEmpty
        ? assistantMsgs.last.content.replaceAll(RegExp(r'\s+'), ' ').trim()
        : 'No response yet';

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chat icon
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.accentAmber.withAlpha(20),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.accentAmber.withAlpha(60)),
              ),
              child: const Center(
                child: Text('🦙', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(conv.title,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),

                  // Preview
                  Text(preview,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),

                  // Meta row
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded,
                          size: 11, color: AppTheme.textMuted),
                      const SizedBox(width: 3),
                      Text(_timeLabel(),
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 11)),
                      const SizedBox(width: 10),
                      const Icon(Icons.chat_bubble_outline_rounded,
                          size: 11, color: AppTheme.textMuted),
                      const SizedBox(width: 3),
                      Text(
                          '${conv.userTurns} turn${conv.userTurns == 1 ? '' : 's'}',
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 11)),
                      if (conv.modelName != null) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            conv.modelName!,
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Delete button
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppTheme.textMuted, size: 18),
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('🗂', style: TextStyle(fontSize: 48)),
            SizedBox(height: 14),
            Text('No saved conversations',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text('Your chats are saved automatically',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          ],
        ),
      );
}
