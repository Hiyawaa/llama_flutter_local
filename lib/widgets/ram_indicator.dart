import 'dart:async';
import 'package:flutter/material.dart';
import '../models/app_theme.dart';
import '../services/ram_guard_service.dart';

class RamIndicator extends StatefulWidget {
  const RamIndicator({super.key});

  @override
  State<RamIndicator> createState() => _RamIndicatorState();
}

class _RamIndicatorState extends State<RamIndicator> {
  RamSnapshot _snapshot = RamSnapshot.empty;
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
    final snap = await RamGuard.read();
    if (mounted && snap.totalKb != 0) {
      setState(() => _snapshot = snap);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_snapshot.totalKb == 0) return const SizedBox.shrink();

    final fraction = _snapshot.fraction;
    final availableGb = _snapshot.availableGb;
    final totalGb = _snapshot.totalGb;

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
