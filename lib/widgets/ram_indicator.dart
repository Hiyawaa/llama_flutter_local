import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/app_theme.dart';

class RamIndicator extends StatefulWidget {
  const RamIndicator({super.key});

  @override
  State<RamIndicator> createState() => _RamIndicatorState();
}

class _RamIndicatorState extends State<RamIndicator> {
  int _availableKb = 0;
  int _totalKb = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      // /proc/meminfo is available on Android (Linux kernel)
      final lines = await File('/proc/meminfo').readAsLines();
      int total = 0, available = 0;
      for (final line in lines) {
        final parts = line.split(':');
        if (parts.length != 2) continue;
        final key = parts[0].trim();
        final kb =
            int.tryParse(parts[1].trim().split(RegExp(r'\s+')).first) ?? 0;
        if (key == 'MemTotal') total = kb;
        if (key == 'MemAvailable') available = kb;
      }
      if (mounted)
        setState(() {
          _totalKb = total;
          _availableKb = available;
        });
    } catch (_) {
      // Not on Android / permission denied — silently skip
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_totalKb == 0) return const SizedBox.shrink();

    final usedKb = _totalKb - _availableKb;
    final fraction = usedKb / _totalKb;
    final availableGb = _availableKb / (1024 * 1024);
    final totalGb = _totalKb / (1024 * 1024);

    // Color shifts green → amber → red as RAM fills up
    final Color barColor;
    if (fraction < 0.6)
      barColor = AppTheme.accentGreen;
    else if (fraction < 0.8)
      barColor = AppTheme.accentAmber;
    else
      barColor = AppTheme.accentRed;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
        color: AppTheme.bgBase,
      ),
      child: Row(
        children: [
          Icon(Icons.memory_rounded, size: 12, color: barColor),
          const SizedBox(width: 5),
          Text(
            'RAM  ${availableGb.toStringAsFixed(1)} GB free / ${totalGb.toStringAsFixed(1)} GB',
            style: TextStyle(
                color: barColor, fontSize: 10.5, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 3,
                backgroundColor: AppTheme.borderColor,
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(fraction * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
