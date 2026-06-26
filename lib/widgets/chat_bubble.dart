import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import 'code_canvas.dart';

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
              maxWidth: MediaQuery.of(context).size.width * 0.85),
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
                  ? _UserContent(content: message.content)
                  : message.isStreaming
                      ? SelectableText(
                          message.content,
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14.5,
                              height: 1.6),
                        )
                      : _FullRender(content: message.content),
        ),
      );

  Widget _time() {
    final h = message.timestamp.hour.toString().padLeft(2, '0');
    final m = message.timestamp.minute.toString().padLeft(2, '0');
    return Text('$h:$m',
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 10));
  }
}

// ── User content (plain text, or a scanned-image card if detected) ──────────

/// Parsed pieces of a message built from a scanned image, matching the
/// format produced by ImageScannerScreen._composeFinalPrompt.
class _ScanContext {
  final String instruction;
  final String? barcode;
  final String? ocrText;
  final List<String> labels;

  const _ScanContext({
    required this.instruction,
    this.barcode,
    this.ocrText,
    this.labels = const [],
  });

  bool get hasDetails =>
      barcode != null || ocrText != null || labels.isNotEmpty;
}

/// Detects the "instruction + detected scan context" shape produced when
/// sending a scanned image to chat, and splits out the raw OCR text/labels
/// so the bubble can show a compact summary instead of dumping them.
_ScanContext? _parseScanContext(String content) {
  const ocrMarker =
      '--- OCR text from the image (may contain recognition errors) ---';
  final hasOcr = content.contains(ocrMarker);
  final barcodeMatch = RegExp(r'^Detected code/link: (.+)$', multiLine: true)
      .firstMatch(content);
  final labelsMatch =
      RegExp(r'^Detected objects/labels: (.+)$', multiLine: true)
          .firstMatch(content);

  if (!hasOcr && barcodeMatch == null && labelsMatch == null) return null;

  // Everything before the first marker line is the user's instruction.
  final markers = <int>[];
  if (barcodeMatch != null) markers.add(barcodeMatch.start);
  if (hasOcr) markers.add(content.indexOf(ocrMarker));
  if (labelsMatch != null) markers.add(labelsMatch.start);
  final cutoff = markers.reduce((a, b) => a < b ? a : b);
  final instruction = content.substring(0, cutoff).trim();

  String? ocrText;
  if (hasOcr) {
    final start = content.indexOf(ocrMarker) + ocrMarker.length;
    var end = content.length;
    if (labelsMatch != null && labelsMatch.start > start) {
      end = labelsMatch.start;
    }
    ocrText = content.substring(start, end).trim();
  }

  final labels = labelsMatch != null
      ? labelsMatch
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList()
      : <String>[];

  return _ScanContext(
    instruction: instruction.isEmpty ? '(scanned image)' : instruction,
    barcode: barcodeMatch?.group(1)?.trim(),
    ocrText: (ocrText != null && ocrText.isNotEmpty) ? ocrText : null,
    labels: labels,
  );
}

class _UserContent extends StatelessWidget {
  final String content;
  const _UserContent({required this.content});

  @override
  Widget build(BuildContext context) {
    final scan = _parseScanContext(content);
    if (scan == null) {
      return SelectableText(
        content,
        style: const TextStyle(
            color: AppTheme.textPrimary, fontSize: 14.5, height: 1.55),
      );
    }
    return _ScannedImageContent(scan: scan);
  }
}

class _ScannedImageContent extends StatefulWidget {
  final _ScanContext scan;
  const _ScannedImageContent({required this.scan});

  @override
  State<_ScannedImageContent> createState() => _ScannedImageContentState();
}

class _ScannedImageContentState extends State<_ScannedImageContent> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scan = widget.scan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(
          scan.instruction,
          style: const TextStyle(
              color: AppTheme.textPrimary, fontSize: 14.5, height: 1.55),
        ),
        if (scan.hasDetails) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: AppTheme.bgBase.withAlpha((0.5 * 255).round()),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color:
                        AppTheme.accentGreen.withAlpha((0.25 * 255).round())),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('📷', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Text(
                    'Scanned image',
                    style: const TextStyle(
                        color: AppTheme.accentGreen,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _summaryLabel(scan),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: AppTheme.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: AppTheme.bgBase.withAlpha((0.4 * 255).round()),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (scan.barcode != null) ...[
                      Text('Code/link',
                          style: TextStyle(
                              color: AppTheme.textMuted.withAlpha(180),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      SelectableText(scan.barcode!,
                          style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                              fontFamily: 'monospace')),
                      const SizedBox(height: 8),
                    ],
                    if (scan.ocrText != null) ...[
                      Text('Recognized text',
                          style: TextStyle(
                              color: AppTheme.textMuted.withAlpha(180),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      SelectableText(scan.ocrText!,
                          style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12.5,
                              height: 1.5)),
                      const SizedBox(height: 8),
                    ],
                    if (scan.labels.isNotEmpty) ...[
                      Text('Detected objects',
                          style: TextStyle(
                              color: AppTheme.textMuted.withAlpha(180),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: scan.labels
                            .map((l) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgSurface,
                                    borderRadius: BorderRadius.circular(20),
                                    border:
                                        Border.all(color: AppTheme.borderColor),
                                  ),
                                  child: Text(l,
                                      style: const TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 11)),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _summaryLabel(_ScanContext scan) {
    final parts = <String>[];
    if (scan.ocrText != null) parts.add('text');
    if (scan.labels.isNotEmpty) parts.add('${scan.labels.length} labels');
    if (scan.barcode != null) parts.add('code');
    return parts.isEmpty ? '' : '· ${parts.join(', ')}';
  }
}

// ── Full render ───────────────────────────────────────────────────────────────

class _FullRender extends StatelessWidget {
  final String content;
  const _FullRender({required this.content});

  static final _codeFence =
      RegExp(r'```(\w*)\n?([\s\S]*?)```', multiLine: true);

  @override
  Widget build(BuildContext context) {
    final segments = <Widget>[];
    int cursor = 0;

    for (final m in _codeFence.allMatches(content)) {
      if (m.start > cursor) {
        segments.add(
            _MixedContentView(content: content.substring(cursor, m.start)));
      }
      final lang = (m.group(1) ?? '').trim();
      final code = (m.group(2) ?? '').trimRight();
      segments.add(CodeBlockCard(block: CodeBlock(language: lang, code: code)));
      cursor = m.end;
    }

    if (cursor < content.length) {
      segments.add(_MixedContentView(content: content.substring(cursor)));
    }
    if (segments.isEmpty) {
      segments.add(_MixedContentView(content: content));
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: segments);
  }
}

// ── Mixed LaTeX + Markdown ────────────────────────────────────────────────────

class _Chunk {
  final String text;
  final bool isBlockLatex;
  const _Chunk(this.text, {this.isBlockLatex = false});
}

class _MixedContentView extends StatelessWidget {
  final String content;
  const _MixedContentView({required this.content});

  static final _blockLatex = RegExp(
    r'\$\$([\s\S]+?)\$\$'
    r'|\\\[([\s\S]+?)\\\]',
    multiLine: true,
  );

  static final _inlineLatex = RegExp(
    r'(?<!\$)\$(?!\$)([^\$\n]+?)\$(?!\$)'
    r'|\\\(([\s\S]+?)\\\)',
  );

  static final _codeSpan = RegExp(r'`[^`\n]*`');

  String _rewriteParens(String segment) => segment.replaceAllMapped(
        RegExp(
          r'(\\[a-zA-Z]+)\(([^()]*)\)'
          r'|(?<![a-zA-Z\\])\(\s*((?:[^()]*?\\[a-zA-Z])[^()]*?)\s*\)',
        ),
        (m) => m.group(1) != null ? m.group(0)! : '\$${m.group(3)!.trim()}\$',
      );

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
    if (cursor < raw.length) buf.write(_rewriteParens(raw.substring(cursor)));
    return buf.toString();
  }

  bool _isBalanced(String latex) {
    int braces = 0;
    for (final ch in latex.runes) {
      if (ch == 0x7B) braces++;
      if (ch == 0x7D) braces--;
      if (braces < 0) return false;
    }
    if (braces != 0) return false;
    return RegExp(r'(?<!\\)\$').allMatches(latex).length % 2 == 0;
  }

  List<_Chunk> _parse(String raw) {
    final text = _preprocess(raw);
    final chunks = <_Chunk>[];
    int cursor = 0;
    for (final m in _blockLatex.allMatches(text)) {
      if (m.start > cursor) {
        chunks.add(_Chunk(text.substring(cursor, m.start)));
      }
      chunks.add(
          _Chunk((m.group(1) ?? m.group(2) ?? '').trim(), isBlockLatex: true));
      cursor = m.end;
    }
    if (cursor < text.length) chunks.add(_Chunk(text.substring(cursor)));
    return chunks;
  }

  @override
  Widget build(BuildContext context) {
    final chunks = _parse(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: chunks
          .map((c) =>
              c.isBlockLatex ? _blockMath(c.text) : _inlineSegment(c.text))
          .toList(),
    );
  }

  Widget _blockMath(String latex) {
    if (!_isBalanced(latex)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectableText(latex,
            style: const TextStyle(
                color: AppTheme.textMuted,
                fontFamily: 'monospace',
                fontSize: 13)),
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
            onErrorFallback: (_) => SelectableText(latex,
                style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontFamily: 'monospace',
                    fontSize: 13)),
          ),
        ),
      ),
    );
  }

  Widget _inlineSegment(String text) {
    final matches = _inlineLatex.allMatches(text).toList();
    if (matches.isEmpty) {
      return MarkdownBody(data: text, selectable: true, styleSheet: _mdStyle());
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
              onErrorFallback: (_) => Text(latex,
                  style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontFamily: 'monospace',
                      fontSize: 13)),
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

// ── Typing dots ───────────────────────────────────────────────────────────────

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
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
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
