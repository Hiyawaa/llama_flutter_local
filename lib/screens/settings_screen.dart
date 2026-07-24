import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';
import '../main.dart' show ThemeController;

class _PromptTemplate {
  final String name;
  final String prompt;
  const _PromptTemplate({required this.name, required this.prompt});
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _systemCtrl;
  late double _temp, _topP, _repeatPenalty;
  late int _maxTokens, _contextSize, _threads;
  late bool _jsonMode, _toolsEnabled;
  late bool _thinkingMode;
  bool _experimentalExpanded = false;

  List<_PromptTemplate> _templates = [];
  String? _selectedTemplateName;
  bool _templatesLoading = true;

  // RAM-aware ceiling for the context slider — filled in asynchronously
  // since it depends on RamGuard reading live device memory. Until it
  // resolves we show the conservative low-RAM ceiling rather than a
  // misleadingly high one.
  int _contextCeiling = 1024;
  bool _contextCeilingLoading = true;

  @override
  void initState() {
    super.initState();
    final p = context.read<ChatProvider>();
    _systemCtrl = TextEditingController(text: p.systemPrompt);
    _temp = p.temperature;
    _topP = p.topP;
    _repeatPenalty = p.repeatPenalty;
    _maxTokens = p.maxTokens;
    _contextSize = p.contextSize;
    _threads = p.threads;
    _jsonMode = p.jsonMode;
    _thinkingMode = p.thinkingMode;
    _toolsEnabled = p.toolsEnabled;
    _loadTemplates();
    _loadContextCeiling();
  }

  Future<void> _loadTemplates() async {
    try {
      final raw =
          await rootBundle.loadString('assets/system_prompt_templates.json');
      final list = jsonDecode(raw) as List<dynamic>;
      final templates = list
          .map((t) => _PromptTemplate(
                name: t['name'] as String,
                prompt: t['prompt'] as String,
              ))
          .toList();
      if (!mounted) return;
      setState(() {
        _templates = templates;
        // If the current system prompt matches a template verbatim,
        // reflect that in the dropdown instead of defaulting to "Custom".
        final match = templates.where((t) => t.prompt == _systemCtrl.text);
        _selectedTemplateName = match.isNotEmpty ? match.first.name : null;
        _templatesLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _templatesLoading = false);
    }
  }

  Future<void> _loadContextCeiling() async {
    final provider = context.read<ChatProvider>();
    final unlocked = await provider.canUnlockLargerContext();
    if (!mounted) return;
    setState(() {
      _contextCeiling = unlocked ? 4096 : 1024;
      _contextCeilingLoading = false;
      // Clamp any already-selected value down if it exceeds the newly
      // discovered ceiling (e.g. RAM dropped since this value was saved).
      if (_contextSize > _contextCeiling) _contextSize = _contextCeiling;
    });
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    super.dispose();
  }

  void _save() {
    context.read<ChatProvider>().updateSettings(
          systemPrompt: _systemCtrl.text,
          temperature: _temp,
          topP: _topP,
          repeatPenalty: _repeatPenalty,
          maxTokens: _maxTokens,
          contextSize: _contextSize,
          threads: _threads,
          jsonMode: _jsonMode,
          thinkingMode: _thinkingMode,
          toolsEnabled: _toolsEnabled,
        );
    Navigator.pop(context);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _showLinkError(url);
    } catch (_) {
      if (mounted) _showLinkError(url);
    }
  }

  void _showLinkError(String url) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open $url')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save',
                style: TextStyle(
                    color: AppTheme.accentAmber, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Appearance'),
          _themeModeSelector(),
          _section('System Prompt'),
          _templateDropdown(),
          const SizedBox(height: 8),
          _textArea(_systemCtrl, hint: 'You are a helpful assistant...'),
          _section('Response Style'),
          _responseStyleSelector(),
          _experimentalSection(),
          _section('About'),
          _aboutCard(),
          _section('Support Development'),
          _donateCard(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Feature 6: theme mode selector ───────────────────────────────────

  // ── Response style: Fast vs Thinking ─────────────────────────────────
  //
  // Replaces asking a casual user to understand temperature/top-P/repeat
  // penalty tradeoffs with two fixed, sensible presets. "Thinking" turns
  // on llamadart's real enableThinking flag (reasoning-capable models
  // emit a chain-of-thought before the final answer) and widens the
  // token budget to give that reasoning room to breathe; "Fast" is the
  // previous default behavior. Anyone who wants to hand-tune the
  // underlying numbers still can, under Experimental / Developer below —
  // this doesn't remove that capability, it just stops leading with it.
  void _applyPreset(bool thinking) {
    setState(() {
      _thinkingMode = thinking;
      if (thinking) {
        _temp = 0.6;
        _maxTokens = 1536;
        _topP = 0.95;
        _repeatPenalty = 1.05;
      } else {
        _temp = 0.2;
        _maxTokens = 768;
        _topP = 0.9;
        _repeatPenalty = 1.1;
      }
    });
  }

  Widget _responseStyleSelector() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppTheme.bgSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _responseStyleOption(
                    label: 'Fast',
                    subtitle: 'Quick, direct answers',
                    icon: Icons.bolt_rounded,
                    selected: !_thinkingMode,
                    onTap: () => _applyPreset(false),
                  ),
                ),
                Expanded(
                  child: _responseStyleOption(
                    label: 'Thinking',
                    subtitle: 'Reasons before answering',
                    icon: Icons.psychology_outlined,
                    selected: _thinkingMode,
                    onTap: () => _applyPreset(true),
                  ),
                ),
              ],
            ),
          ),
          if (_thinkingMode)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
              child: Text(
                'Only works with models trained for reasoning (e.g. Qwen3-style '
                'think/no-think models). Other models will just ignore this and '
                'answer normally. Uses more tokens and takes longer per reply.',
                style: TextStyle(
                    color: AppTheme.textMuted.withAlpha(200), fontSize: 11),
              ),
            ),
        ],
      );

  Widget _responseStyleOption({
    required String label,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accentAmber.withAlpha(35)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? Border.all(color: AppTheme.accentAmber.withAlpha(120))
                : null,
          ),
          child: Column(
            children: [
              Icon(icon,
                  size: 18,
                  color:
                      selected ? AppTheme.accentAmber : AppTheme.textSecondary),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? AppTheme.accentAmber
                          : AppTheme.textPrimary,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
              const SizedBox(height: 2),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: selected
                          ? AppTheme.accentAmber.withAlpha(200)
                          : AppTheme.textMuted)),
            ],
          ),
        ),
      );

  Widget _themeModeSelector() {
    final controller = context.watch<ThemeController>();
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: ThemeMode.values.map((mode) {
          final selected = controller.mode == mode;
          final label = switch (mode) {
            ThemeMode.system => 'System',
            ThemeMode.light => 'Light',
            ThemeMode.dark => 'Dark',
          };
          final icon = switch (mode) {
            ThemeMode.system => Icons.brightness_auto_rounded,
            ThemeMode.light => Icons.light_mode_rounded,
            ThemeMode.dark => Icons.dark_mode_rounded,
          };
          return Expanded(
            child: GestureDetector(
              onTap: () => controller.setMode(mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 10),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentAmber.withAlpha(35)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: selected
                      ? Border.all(color: AppTheme.accentAmber.withAlpha(120))
                      : null,
                ),
                child: Column(
                  children: [
                    Icon(icon,
                        size: 18,
                        color: selected
                            ? AppTheme.accentAmber
                            : AppTheme.textSecondary),
                    const SizedBox(height: 4),
                    Text(label,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: selected
                                ? AppTheme.accentAmber
                                : AppTheme.textSecondary,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400)),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Feature 8: template dropdown ─────────────────────────────────────

  Widget _templateDropdown() {
    if (_templatesLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppTheme.accentAmber),
        ),
      );
    }
    if (_templates.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _selectedTemplateName,
          hint: const Text('Custom (edit below)',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13.5)),
          dropdownColor: AppTheme.bgSurface,
          icon: const Icon(Icons.expand_more_rounded,
              color: AppTheme.textSecondary),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
          items: _templates
              .map((t) => DropdownMenuItem(value: t.name, child: Text(t.name)))
              .toList(),
          onChanged: (name) {
            final template = _templates.firstWhere((t) => t.name == name);
            setState(() {
              _selectedTemplateName = name;
              _systemCtrl.text = template.prompt;
            });
          },
        ),
      ),
    );
  }

  // ── RAM-aware context size ───────────────────────────────────────────

  Widget _contextSizeSlider() {
    if (_contextCeilingLoading) {
      return _slider(
        'Context Size',
        _contextSize.toDouble(),
        512,
        1024,
        30,
        (v) => setState(() => _contextSize = v.round()),
        format: (v) => v.round().toString(),
        hint: 'Checking available RAM…',
      );
    }
    final low = _contextCeiling <= 1024;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _slider(
          'Context Size',
          _contextSize.toDouble().clamp(512, _contextCeiling.toDouble()),
          512,
          _contextCeiling.toDouble(),
          low ? 8 : 30,
          (v) => setState(() => _contextSize = v.round()),
          format: (v) => v.round().toString(),
          hint: low
              ? 'Capped at 1024 for this device\'s available RAM '
                  '(reload model to apply)'
              : 'Tokens of context memory (reload model to apply)',
        ),
      ],
    );
  }

  // ── Experimental / Developer section ─────────────────────────────────
  //
  // JSON Mode and Tool Calling both depend on a small local model
  // reliably following a specific output contract (valid JSON, or a
  // structured tool-call envelope) — something even large frontier
  // models sometimes fumble, and the 500M–3B models this app targets on
  // 4GB devices fumble more often. Neither feature is broken, but their
  // reliability ceiling is capped by model capability, not app code.
  // Collapsed by default and clearly labeled so casual users aren't
  // steered toward toggles that are more likely to produce a confusing
  // result than a working one.
  Widget _experimentalSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 10),
          child: GestureDetector(
            onTap: () =>
                setState(() => _experimentalExpanded = !_experimentalExpanded),
            child: Row(
              children: [
                const Icon(Icons.science_outlined,
                    size: 14, color: AppTheme.accentAmber),
                const SizedBox(width: 6),
                const Text('EXPERIMENTAL / DEVELOPER',
                    style: TextStyle(
                        color: AppTheme.accentAmber,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
                const Spacer(),
                Icon(
                  _experimentalExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: AppTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_experimentalExpanded) ...[
          _warningNote(
            'These features depend on the model reliably following a strict '
            'output format. Small on-device models (which is what this app '
            'targets for 4GB RAM) follow that format less consistently than '
            'large cloud models — expect occasional malformed or confusing '
            'output. Off by default for a reason.',
          ),
          _switchTile(
            title: 'JSON Mode',
            subtitle: 'Force strict JSON output, no prose or Markdown. '
                'Disables auto-continue for unfinished responses. Useful '
                'only if something else is going to parse the response — '
                'not for normal chatting.',
            value: _jsonMode,
            onChanged: (v) => setState(() => _jsonMode = v),
          ),
          _switchTile(
            title: 'Tool Calling',
            subtitle: 'Let the model use a calculator and weather lookup '
                'when it decides a tool would help. Requires the model to '
                'correctly emit a structured tool-call request — smaller '
                'models may ignore it or get the format wrong.',
            value: _toolsEnabled,
            onChanged: (v) => setState(() => _toolsEnabled = v),
          ),
          if (_jsonMode && _toolsEnabled)
            _warningNote(
              'JSON Mode and Tool Calling both shape the model\'s output '
              'format — enabling both at once can confuse smaller models. '
              'Consider using one at a time.',
            ),
          const SizedBox(height: 8),
          Text('MANUAL GENERATION CONTROLS'.toUpperCase(),
              style: const TextStyle(
                  color: AppTheme.accentAmber,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1)),
          const SizedBox(height: 4),
          const Text(
            'Fast/Thinking above sets these automatically. Adjust manually '
            'only if you know what you\'re changing — values here are '
            'overwritten the next time you pick Fast or Thinking.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          _slider(
              'Temperature', _temp, 0, 2, 40, (v) => setState(() => _temp = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Higher = more creative'),
          _slider('Max Tokens', _maxTokens.toDouble(), 128, 8192, 63,
              (v) => setState(() => _maxTokens = v.round()),
              format: (v) => v.round().toString(),
              hint: 'Max response length; lower is faster'),
          _slider('Top-P', _topP, 0, 1, 20, (v) => setState(() => _topP = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Nucleus sampling threshold'),
          _slider('Repeat Penalty', _repeatPenalty, 1, 2, 20,
              (v) => setState(() => _repeatPenalty = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Penalise repeated tokens'),
          _contextSizeSlider(),
          _slider('CPU Threads', _threads.toDouble(), 0, 16, 16,
              (v) => setState(() => _threads = v.round()),
              format: (v) => v.round() == 0 ? 'Auto' : v.round().toString(),
              hint: '0 lets llama.cpp choose (reload model to apply)'),
        ],
      ],
    );
  }

  Widget _warningNote(String text) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.accentAmber.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accentAmber.withAlpha(60)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded,
                size: 15, color: AppTheme.accentAmber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11.5)),
            ),
          ],
        ),
      );

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
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
                  Text(title,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppTheme.accentAmber,
            ),
          ],
        ),
      );

  // ── About card ─────────────────────────────────────────────────────────

  Widget _aboutCard() => Container(
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color:
                          AppTheme.accentAmber.withAlpha((0.1 * 255).round()),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppTheme.accentAmber
                              .withAlpha((0.3 * 255).round())),
                    ),
                    child: const Center(
                      child: Text('🦙', style: TextStyle(fontSize: 22)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('LlamaDart',
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Version 1.0.0',
                            style: TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppTheme.borderColor),
            _linkTile(
              icon: Icons.code_rounded,
              label: 'Source code (GitHub)',
              onTap: () =>
                  _openUrl('https://github.com/Hiyawaa/llama_flutter_local'),
            ),
            _linkTile(
              icon: Icons.bug_report_outlined,
              label: 'Report an issue',
              onTap: () => _openUrl(
                  'https://github.com/Hiyawaa/llama_flutter_local/issues'),
            ),
            _linkTile(
              icon: Icons.description_outlined,
              label: 'Open-source licenses',
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'LlamaDart',
                applicationVersion: '1.0.0',
              ),
              isLast: true,
            ),
          ],
        ),
      );

  // ── Donate card ────────────────────────────────────────────────────────

  Widget _donateCard() => Container(
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
              'LlamaDart is free and runs entirely on your device. '
              'If you find it useful, consider supporting development ❤️',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            _donateButton(
              emoji: '☕',
              label: 'Buy me a coffee',
              color: AppTheme.accentAmber,
              onTap: () => _openUrl('https://buymeacoffee.com/yourname'),
            ),
            const SizedBox(height: 8),
            _donateButton(
              emoji: '💖',
              label: 'GitHub Sponsors',
              color: AppTheme.accentGreen,
              onTap: () => _openUrl('https://github.com/sponsors/yourname'),
            ),
            const SizedBox(height: 8),
            _donateButton(
              emoji: '🅿️',
              label: 'PayPal',
              color: AppTheme.accentBlue,
              onTap: () => _openUrl('https://paypal.me/yourname'),
            ),
          ],
        ),
      );

  Widget _donateButton({
    required String emoji,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) =>
      SizedBox(
        width: double.infinity,
        height: 46,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Text(emoji, style: const TextStyle(fontSize: 16)),
          label: Text(label,
              style: TextStyle(
                  color: color, fontSize: 13.5, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: color.withAlpha((0.4 * 255).round())),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );

  Widget _linkTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isLast = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: isLast
              ? null
              : const BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: AppTheme.borderColor)),
                ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13.5)),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppTheme.textMuted),
            ],
          ),
        ),
      );

  // ── Shared widgets ────────────────────────────────────────────────────

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 10),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.accentAmber,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );

  Widget _textArea(TextEditingController ctrl, {String hint = ''}) => Container(
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: TextField(
          controller: ctrl,
          maxLines: 4,
          onChanged: (_) {
            // Free-typing counts as going "custom" — clear the dropdown
            // selection so it doesn't misleadingly still show a preset
            // name once the user has diverged from it.
            if (_selectedTemplateName != null) {
              final matches =
                  _templates.where((t) => t.name == _selectedTemplateName);
              final current = matches.isNotEmpty ? matches.first : null;
              if (current != null && current.prompt != ctrl.text) {
                setState(() => _selectedTemplateName = null);
              }
            }
          },
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AppTheme.textMuted),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
      );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged, {
    required String Function(double) format,
    String hint = '',
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          AppTheme.accentAmber.withAlpha((0.1 * 255).round()),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: AppTheme.accentAmber
                              .withAlpha((0.3 * 255).round())),
                    ),
                    child: Text(format(value),
                        style: const TextStyle(
                            color: AppTheme.accentAmber,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppTheme.accentAmber,
                  inactiveTrackColor: AppTheme.borderColor,
                  thumbColor: AppTheme.accentAmber,
                  overlayColor:
                      AppTheme.accentAmber.withAlpha((0.1 * 255).round()),
                  trackHeight: 2,
                ),
                child: Slider(
                    value: value.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: onChanged),
              ),
              if (hint.isNotEmpty)
                Text(hint,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
        ),
      );
}
