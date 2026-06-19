import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _read());
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

      int total = 0;
      int memAvailable = 0;
      int memFree = 0;
      int buffers = 0;
      int cached = 0;
      bool hasMemAvailable = false;

      for (final line in lines) {
        final parts = line.split(':');
        if (parts.length != 2) continue;
        final key = parts[0].trim();
        final kb =
            int.tryParse(parts[1].trim().split(RegExp(r'\s+')).first) ?? 0;

        switch (key) {
          case 'MemTotal':
            total = kb;
            break;
          case 'MemAvailable':
            memAvailable = kb;
            hasMemAvailable = true;
            break;
          case 'MemFree':
            memFree = kb;
            break;
          case 'Buffers':
            buffers = kb;
            break;
          case 'Cached':
            cached = kb;
            break;
        }
      }

      // Some kernels (older / custom ROMs) don't expose MemAvailable.
      // Fall back to the classic free+buffers+cached approximation so the
      // bar doesn't get stuck pinned at 100%.
      final available =
          hasMemAvailable ? memAvailable : (memFree + buffers + cached);

      if (total == 0) {
        // Couldn't parse anything meaningful — skip this tick rather than
        // showing a bogus 0/0 state.
        return;
      }

      if (mounted) {
        setState(() {
          _totalKb = total;
          _availableKb = available;
        });
      }
    } catch (e) {
      // Not on Android / permission denied — log so it's visible in debug
      // instead of failing silently forever.
      if (kDebugMode) {
        debugPrint('RamIndicator: failed to read /proc/meminfo: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_totalKb == 0) return const SizedBox.shrink();

    final usedKb = _totalKb - _availableKb;
    final fraction = (usedKb / _totalKb).clamp(0.0, 1.0);
    final availableGb = _availableKb / (1024 * 1024);
    final totalGb = _totalKb / (1024 * 1024);

    // Color shifts green → amber → red as RAM fills up
    final Color barColor;
    if (fraction < 0.6) {
      barColor = AppTheme.accentGreen;
    } else if (fraction < 0.8) {
      barColor = AppTheme.accentAmber;
    } else {
      barColor = AppTheme.accentRed;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
        color: AppTheme.bgBase,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below this width there isn't room for the full "free / total"
          // label without overflowing — drop to a compact layout instead.
          final compact = constraints.maxWidth < 220;

          final label = compact
              ? '${availableGb.toStringAsFixed(1)} GB free'
              : 'RAM  ${availableGb.toStringAsFixed(1)} GB free / ${totalGb.toStringAsFixed(1)} GB';

          final bar = ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: fraction, end: fraction),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 3,
                backgroundColor: AppTheme.borderColor,
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
          );

          return Row(
            children: [
              Icon(Icons.memory_rounded, size: 12, color: barColor),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                      color: barColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: bar),
              const SizedBox(width: 8),
              Text(
                '${(fraction * 100).toStringAsFixed(0)}%',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ],
          );
        },
      ),
    );
  }
}
