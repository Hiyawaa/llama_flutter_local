import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const ChatBubble({super.key, required this.message});

  bool get isUser => message.role == 'user';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) _avatar(),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                _bubble(context),
                const SizedBox(height: 2),
                _time(),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isUser) _avatar(),
        ],
      ),
    );
  }

  Widget _avatar() => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (isUser ? AppTheme.accentGreen : AppTheme.accentAmber)
              .withAlpha((0.12 * 255).round()),
          border: Border.all(
            color: (isUser ? AppTheme.accentGreen : AppTheme.accentAmber)
                .withAlpha((0.35 * 255).round()),
          ),
        ),
        child: Center(
          child:
              Text(isUser ? '👤' : '🦙', style: const TextStyle(fontSize: 13)),
        ),
      );

  Widget _bubble(BuildContext context) => GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: message.content));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied'),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  ? AppTheme.accentGreen.withAlpha((0.2 * 255).round())
                  : AppTheme.borderColor,
            ),
          ),
          child: message.content.isEmpty && message.isStreaming
              ? _TypingDots()
              : isUser
                  ? SelectableText(
                      message.content,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14.5,
                          height: 1.55),
                    )
                  : MarkdownBody(
                      data: message.content,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 14.5,
                            height: 1.6),
                        code: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: AppTheme.accentAmber),
                        codeblockDecoration: BoxDecoration(
                          color: AppTheme.bgBase,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        strong: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
        ),
      );

  Widget _time() {
    final h = message.timestamp.hour.toString().padLeft(2, '0');
    final m = message.timestamp.minute.toString().padLeft(2, '0');
    return Text('$h:$m',
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 10));
  }
}

class _TypingDots extends StatefulWidget {
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final opacity =
              (1 - ((_ctrl.value - i / 3).abs() % 1.0 - 0.5).abs() * 2)
                  .clamp(0.2, 1.0);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Opacity(
              opacity: opacity,
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                    color: AppTheme.accentAmber, shape: BoxShape.circle),
              ),
            ),
          );
        }),
      ),
    );
  }
}
