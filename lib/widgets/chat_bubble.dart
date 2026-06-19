import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
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
          child: Text(
            isUser ? '👤' : '🦙',
            style: const TextStyle(fontSize: 13),
          ),
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
              ? const _TypingDots()
              : isUser
                  ? SelectableText(
                      message.content,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14.5,
                          height: 1.55),
                    )
                  // While streaming render plain text — partial LaTeX delimiters
                  // cause malformed-match bugs until the full response arrives.
                  : message.isStreaming
                      ? SelectableText(
                          message.content,
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14.5,
                              height: 1.6),
                        )
                      : _MixedContentView(content: message.content),
        ),
      );

  Widget _time() {
    final h = message.timestamp.hour.toString().padLeft(2, '0');
    final m = message.timestamp.minute.toString().padLeft(2, '0');
    return Text('$h:$m',
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 10));
  }
}

// ---------------------------------------------------------------------------
// Mixed content renderer — handles LaTeX + Markdown
//
// Block delimiters:  $$...$$  |  \[...\]
// Inline delimiters: $...$   |  \(...\)
//
// FIX: Removed the Qwen [ ... ] pattern — too greedy, causes false positives.
// FIX: _rewriteParens now skips \cmd(...) arguments (sin, cos, frac, etc.)
// FIX: \{ and \} are now preserved correctly inside math blocks.
// ---------------------------------------------------------------------------

class _Chunk {
  final String text;
  final bool isBlockLatex;
  const _Chunk(this.text, {this.isBlockLatex = false});
}

class _MixedContentView extends StatelessWidget {
  final String content;
  const _MixedContentView({required this.content});

  // ── Block math: $$...$$ and \[...\] only ─────────────────────────────────
  // FIX: Removed the [ \cmd ] Qwen pattern — it matched \mathcal{L}\{...\}
  // and other LaTeX constructs incorrectly.
  static final _blockLatex = RegExp(
    r'\$\$([\s\S]+?)\$\$' // $$...$$
    r'|\\\[([\s\S]+?)\\\]', // \[...\]
    multiLine: true,
  );

  // ── Inline math: $...$ and \(...\) ───────────────────────────────────────
  static final _inlineLatex = RegExp(
    r'(?<!\$)\$(?!\$)([^\$\n]+?)\$(?!\$)' // $...$
    r'|\\\(([\s\S]+?)\\\)', // \(...\)
  );

  // Code spans — skip preprocessing inside these
  static final _codeSpan = RegExp(r'```[\s\S]*?```|`[^`\n]*`');

  // ── FIX: _rewriteParens ──────────────────────────────────────────────────
  // OLD behaviour: converted ANY ( \cmd ... ) to $...$, including \sin(\omega t)
  // NEW behaviour: only converts STANDALONE ( \cmd ... ) that are NOT
  // immediately preceded by a backslash-command name.
  //
  // Strategy: match \cmd(...) first and keep it untouched; only convert
  // bare-paren groups that are not function arguments.
  String _rewriteParens(String segment) {
    // Pattern A: \commandName(...)  → keep as-is (it's a function argument)
    // Pattern B: ( \latex expr )    → convert to $\latex expr$
    return segment.replaceAllMapped(
      RegExp(
        r'(\\[a-zA-Z]+)\(([^()]*)\)' // A: \cmd(...)
        r'|(?<![a-zA-Z\\])\(\s*((?:[^()]*?\\[a-zA-Z])[^()]*?)\s*\)', // B: standalone
      ),
      (m) {
        if (m.group(1) != null) {
          // Pattern A matched — leave \cmd(...) completely untouched
          return m.group(0)!;
        }
        // Pattern B matched — it's a standalone ( \latex ) group
        return '\$${m.group(3)!.trim()}\$';
      },
    );
  }

  String _preprocess(String raw) {
    final buf = StringBuffer();
    int cursor = 0;
    for (final m in _codeSpan.allMatches(raw)) {
      if (m.start > cursor) {
        buf.write(_rewriteParens(raw.substring(cursor, m.start)));
      }
      buf.write(raw.substring(m.start, m.end));
      cursor = m.end;
    }
    if (cursor < raw.length) {
      buf.write(_rewriteParens(raw.substring(cursor)));
    }
    return buf.toString();
  }

  // ── Sanity check before handing to Math.tex ───────────────────────────────
  bool _isBalanced(String latex) {
    int braces = 0;
    for (final ch in latex.runes) {
      if (ch == 0x7B) braces++; // {
      if (ch == 0x7D) braces--; // }
      if (braces < 0) return false;
    }
    if (braces != 0) return false;
    // Unescaped $ count must be even
    final dollars = RegExp(r'(?<!\\)\$').allMatches(latex).length;
    if (dollars % 2 != 0) return false;
    return true;
  }

  List<_Chunk> _parse(String raw) {
    final text = _preprocess(raw);
    final chunks = <_Chunk>[];
    int cursor = 0;

    for (final m in _blockLatex.allMatches(text)) {
      if (m.start > cursor) {
        chunks.add(_Chunk(text.substring(cursor, m.start)));
      }
      final latex = (m.group(1) ?? m.group(2) ?? '').trim();
      chunks.add(_Chunk(latex, isBlockLatex: true));
      cursor = m.end;
    }
    if (cursor < text.length) {
      chunks.add(_Chunk(text.substring(cursor)));
    }
    return chunks;
  }

  @override
  Widget build(BuildContext context) {
    final chunks = _parse(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: chunks.map((c) {
        if (c.isBlockLatex) return _blockMath(c.text);
        return _inlineSegment(c.text);
      }).toList(),
    );
  }

  Widget _blockMath(String latex) {
    if (!_isBalanced(latex)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectableText(
          latex,
          style: const TextStyle(
              color: AppTheme.textMuted, fontFamily: 'monospace', fontSize: 13),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            latex,
            mathStyle: MathStyle.display,
            textStyle:
                const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
            onErrorFallback: (_) => SelectableText(
              latex,
              style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontFamily: 'monospace',
                  fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inlineSegment(String text) {
    final matches = _inlineLatex.allMatches(text).toList();

    if (matches.isEmpty) {
      return MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: _mdStyle(),
      );
    }

    final spans = <InlineSpan>[];
    int cursor = 0;

    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(
          text: text.substring(cursor, m.start),
          style: const TextStyle(
              color: AppTheme.textPrimary, fontSize: 14.5, height: 1.6),
        ));
      }
      final latex = (m.group(1) ?? m.group(2) ?? '').trim();
      if (!_isBalanced(latex)) {
        spans.add(TextSpan(
          text: m.group(0),
          style: const TextStyle(
              color: AppTheme.textMuted, fontFamily: 'monospace', fontSize: 13),
        ));
      } else {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Math.tex(
              latex,
              mathStyle: MathStyle.text,
              textStyle:
                  const TextStyle(color: AppTheme.textPrimary, fontSize: 14.5),
              onErrorFallback: (_) => Text(
                latex,
                style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontFamily: 'monospace',
                    fontSize: 13),
              ),
            ),
          ),
        ));
      }
      cursor = m.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(
        text: text.substring(cursor),
        style: const TextStyle(
            color: AppTheme.textPrimary, fontSize: 14.5, height: 1.6),
      ));
    }

    return SelectableText.rich(TextSpan(children: spans));
  }

  MarkdownStyleSheet _mdStyle() => MarkdownStyleSheet(
        p: const TextStyle(
            color: AppTheme.textPrimary, fontSize: 14.5, height: 1.6),
        code: const TextStyle(
            fontFamily: 'monospace', fontSize: 13, color: AppTheme.accentAmber),
        codeblockDecoration: BoxDecoration(
          color: AppTheme.bgBase,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        strong: const TextStyle(
            color: AppTheme.textPrimary, fontWeight: FontWeight.w700),
        em: const TextStyle(
            color: AppTheme.textPrimary, fontStyle: FontStyle.italic),
        blockquote: const TextStyle(
            color: AppTheme.textMuted, fontSize: 14, height: 1.6),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
                color: AppTheme.accentAmber.withAlpha((0.5 * 255).round()),
                width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        h1: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700),
        h2: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700),
        h3: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600),
        listBullet:
            const TextStyle(color: AppTheme.textPrimary, fontSize: 14.5),
      );
}

// ---------------------------------------------------------------------------
// Typing indicator
// ---------------------------------------------------------------------------

class _TypingDots extends StatefulWidget {
  const _TypingDots();

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
