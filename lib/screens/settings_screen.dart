import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
    _systemCtrl  = TextEditingController(text: p.systemPrompt);
    _temp        = p.temperature;
    _topP        = p.topP;
    _repeatPenalty = p.repeatPenalty;
    _maxTokens   = p.maxTokens;
    _contextSize = p.contextSize;
    _threads     = p.threads;
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    super.dispose();
  }

  void _save() {
    context.read<ChatProvider>().updateSettings(
      systemPrompt:  _systemCtrl.text,
      temperature:   _temp,
      topP:          _topP,
      repeatPenalty: _repeatPenalty,
      maxTokens:     _maxTokens,
      contextSize:   _contextSize,
      threads:       _threads,
    );
    Navigator.pop(context);
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
                    color: AppTheme.accentAmber,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('System Prompt'),
          _textArea(_systemCtrl,
              hint: 'You are a helpful assistant...'),
          _section('Generation'),
          _slider('Temperature', _temp, 0, 2, 40,
              (v) => setState(() => _temp = v),
              format: (v) => v.toStringAsFixed(2),
              hint: 'Higher = more creative'),
          _slider('Max Tokens', _maxTokens.toDouble(), 128, 8192, 63,
              (v) => setState(() => _maxTokens = v.round()),
              format: (v) => v.round().toString(),
              hint: 'Max tokens per response'),
          _slider('Top-P', _topP, 0, 1, 20,
              (v) => setState(() => _topP = v),
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
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 10),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.accentAmber,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );

  Widget _textArea(TextEditingController ctrl, {String hint = ''}) =>
      Container(
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.accentAmber.withAlpha((0.1 * 255).round()),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: AppTheme.accentAmber.withAlpha((0.3 * 255).round())),
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
                  overlayColor: AppTheme.accentAmber.withAlpha((0.1 * 255).round()),
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
