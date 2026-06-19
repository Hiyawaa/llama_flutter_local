import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/app_theme.dart';

// ── Language color map ────────────────────────────────────────────────────────
const _langColors = {
  'dart': Color(0xFF54C5F8),
  'flutter': Color(0xFF54C5F8),
  'python': Color(0xFFFFD43B),
  'javascript': Color(0xFFF7DF1E),
  'js': Color(0xFFF7DF1E),
  'typescript': Color(0xFF3178C6),
  'ts': Color(0xFF3178C6),
  'kotlin': Color(0xFF7F52FF),
  'java': Color(0xFFEA2D2E),
  'swift': Color(0xFFFF6B35),
  'rust': Color(0xFFCE4A00),
  'go': Color(0xFF00ACD7),
  'cpp': Color(0xFF00599C),
  'c': Color(0xFF555555),
  'html': Color(0xFFE34C26),
  'css': Color(0xFF264DE4),
  'bash': Color(0xFF4EAA25),
  'shell': Color(0xFF4EAA25),
  'sh': Color(0xFF4EAA25),
  'sql': Color(0xFFE38C00),
  'json': Color(0xFF40BFB0),
  'yaml': Color(0xFFCB171E),
  'xml': Color(0xFFFF6600),
  'markdown': Color(0xFF083FA1),
  'md': Color(0xFF083FA1),
};

Color _colorForLang(String lang) =>
    _langColors[lang.toLowerCase()] ?? AppTheme.accentAmber;

// ── Parse code blocks from markdown ──────────────────────────────────────────

class CodeBlock {
  final String language;
  final String code;
  CodeBlock({required this.language, required this.code});
}

List<CodeBlock> extractCodeBlocks(String content) {
  final pattern = RegExp(r'```(\w*)\n?([\s\S]*?)```', multiLine: true);
  return pattern.allMatches(content).map((m) {
    final lang = (m.group(1) ?? '').trim();
    final code = (m.group(2) ?? '').trimRight();
    return CodeBlock(language: lang, code: code);
  }).toList();
}

// ── Code canvas bottom sheet ──────────────────────────────────────────────────

void showCodeCanvas(BuildContext context, CodeBlock block) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CodeCanvasSheet(block: block),
  );
}

class _CodeCanvasSheet extends StatefulWidget {
  final CodeBlock block;
  const _CodeCanvasSheet({required this.block});

  @override
  State<_CodeCanvasSheet> createState() => _CodeCanvasSheetState();
}

class _CodeCanvasSheetState extends State<_CodeCanvasSheet> {
  bool _copied = false;
  bool _showLines = true;
  double _fontSize = 13;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.block.code));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.block.language;
    final langColor = _colorForLang(lang);
    final lines = widget.block.code.split('\n');
    final lineCount = lines.length;
    final h = MediaQuery.of(context).size.height;

    return Container(
      height: h * 0.88,
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D10),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        children: [
          // ── Handle ──────────────────────────────────────────────────────
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                // Language badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: langColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: langColor.withAlpha(80)),
                  ),
                  child: Text(
                    lang.isEmpty ? 'code' : lang,
                    style: TextStyle(
                        color: langColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text('$lineCount line${lineCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
                const Spacer(),

                // Font size controls
                _HeaderBtn(
                  icon: Icons.text_decrease_rounded,
                  onTap: () =>
                      setState(() => _fontSize = (_fontSize - 1).clamp(10, 20)),
                  tooltip: 'Decrease font',
                ),
                _HeaderBtn(
                  icon: Icons.text_increase_rounded,
                  onTap: () =>
                      setState(() => _fontSize = (_fontSize + 1).clamp(10, 20)),
                  tooltip: 'Increase font',
                ),

                // Line numbers toggle
                _HeaderBtn(
                  icon: Icons.format_list_numbered_rounded,
                  onTap: () => setState(() => _showLines = !_showLines),
                  tooltip: 'Toggle line numbers',
                  active: _showLines,
                ),

                // Copy button
                GestureDetector(
                  onTap: _copy,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _copied
                          ? AppTheme.accentGreen.withAlpha(30)
                          : AppTheme.accentAmber.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _copied
                            ? AppTheme.accentGreen.withAlpha(100)
                            : AppTheme.accentAmber.withAlpha(100),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 14,
                          color: _copied
                              ? AppTheme.accentGreen
                              : AppTheme.accentAmber,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? 'Copied!' : 'Copy',
                          style: TextStyle(
                            color: _copied
                                ? AppTheme.accentGreen
                                : AppTheme.accentAmber,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                // Close
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AppTheme.textMuted, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          const Divider(color: AppTheme.borderColor, height: 1),

          // ── Code body ────────────────────────────────────────────────────
          Expanded(
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _showLines
                    ? _CodeWithLineNumbers(
                        lines: lines,
                        fontSize: _fontSize,
                        langColor: langColor,
                      )
                    : SelectableText(
                        widget.block.code,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize,
                          color: AppTheme.textPrimary,
                          height: 1.55,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Code with line numbers ────────────────────────────────────────────────────

class _CodeWithLineNumbers extends StatelessWidget {
  final List<String> lines;
  final double fontSize;
  final Color langColor;

  const _CodeWithLineNumbers({
    required this.lines,
    required this.fontSize,
    required this.langColor,
  });

  @override
  Widget build(BuildContext context) {
    final numWidth = (lines.length.toString().length * (fontSize * 0.6) + 16)
        .clamp(32.0, 64.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Line numbers column
        SizedBox(
          width: numWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(
                lines.length,
                (i) => Padding(
                      padding: EdgeInsets.only(
                          right: 12, bottom: (fontSize * 0.55).roundToDouble()),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: fontSize - 1,
                          color: AppTheme.textMuted,
                          height: 1.55,
                        ),
                      ),
                    )),
          ),
        ),

        // Vertical divider
        Container(
          width: 1,
          color: AppTheme.borderColor,
          margin: const EdgeInsets.only(right: 12),
        ),

        // Code
        Expanded(
          child: SelectableText(
            lines.join('\n'),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: fontSize,
              color: AppTheme.textPrimary,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Header button ─────────────────────────────────────────────────────────────

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool active;

  const _HeaderBtn({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: IconButton(
          icon: Icon(icon, size: 18),
          color: active ? AppTheme.accentAmber : AppTheme.textMuted,
          onPressed: onTap,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
        ),
      );
}

// ── Inline code block card (used in ChatBubble) ───────────────────────────────

class CodeBlockCard extends StatelessWidget {
  final CodeBlock block;

  const CodeBlockCard({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final lang = block.language;
    final langColor = _colorForLang(lang);
    final lines = block.code.split('\n');
    final preview = lines.take(6).join('\n');
    final hasMore = lines.length > 6;

    return GestureDetector(
      onTap: () => showCodeCanvas(context, block),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: langColor.withAlpha(15),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(10)),
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: langColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 7),
                  Text(lang.isEmpty ? 'code' : lang,
                      style: TextStyle(
                          color: langColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text('${lines.length} lines',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                  const Spacer(),
                  const Icon(Icons.open_in_full_rounded,
                      color: AppTheme.textMuted, size: 13),
                  const SizedBox(width: 4),
                  const Text('Tap to expand',
                      style:
                          TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),

            // Code preview
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                hasMore ? '$preview\n…' : preview,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: AppTheme.textPrimary,
                  height: 1.5,
                ),
                maxLines: 7,
                overflow: TextOverflow.fade,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
