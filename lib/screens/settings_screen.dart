import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _systemCtrl;
  late double _temp, _topP, _repeatPenalty;
  late int _maxTokens, _contextSize, _threads;

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
          _section('System Prompt'),
          _textArea(_systemCtrl, hint: 'You are a helpful assistant...'),
          _section('Generation'),
          _slider(
              'Temperature', _temp, 0, 2, 40, (v) => setState(() => _temp = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Higher = more creative'),
          _slider('Max Tokens', _maxTokens.toDouble(), 128, 8192, 63,
              (v) => setState(() => _maxTokens = v.round()),
              format: (v) => v.round().toString(),
              hint: 'Max tokens per response'),
          _slider('Top-P', _topP, 0, 1, 20, (v) => setState(() => _topP = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Nucleus sampling threshold'),
          _slider('Repeat Penalty', _repeatPenalty, 1, 2, 20,
              (v) => setState(() => _repeatPenalty = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Penalise repeated tokens'),
          _section('Performance'),
          _slider('Context Size', _contextSize.toDouble(), 512, 8192, 30,
              (v) => setState(() => _contextSize = v.round()),
              format: (v) => v.round().toString(),
              hint: 'Tokens of context memory (reload model to apply)'),
          _slider('CPU Threads', _threads.toDouble(), 1, 8, 7,
              (v) => setState(() => _threads = v.round()),
              format: (v) => v.round().toString(),
              hint: 'More threads = faster (reload model to apply)'),
          _section('About'),
          _aboutCard(),
          _section('Support Development'),
          _donateCard(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

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
                    value: value,
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
