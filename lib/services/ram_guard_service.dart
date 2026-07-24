import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Snapshot of device memory at a point in time, in KB (raw) and MB (helpers).
class RamSnapshot {
  final int totalKb;
  final int availableKb;

  const RamSnapshot({required this.totalKb, required this.availableKb});

  int get usedKb => totalKb - availableKb;
  double get fraction => totalKb == 0 ? 0 : (usedKb / totalKb).clamp(0.0, 1.0);

  double get totalMb => totalKb / 1024;
  double get availableMb => availableKb / 1024;
  double get totalGb => totalKb / (1024 * 1024);
  double get availableGb => availableKb / (1024 * 1024);

  static const empty = RamSnapshot(totalKb: 0, availableKb: 0);
}

/// Central gatekeeper for any memory-heavy operation in the app:
/// loading a GGUF model, loading an mmproj vision projector, restoring a
/// KV-cache, or spinning up the RAG embedding model.
///
/// Every feature that wants to allocate a large chunk of memory MUST go
/// through `canLoad`/`ensureCanLoad` first, rather than attempting the
/// operation and hoping the OS doesn't OOM-kill the process. On 4GB
/// devices there is no graceful recovery from an OOM kill — the app just
/// disappears — so refusing up front is the only real safety net we have.
class RamGuard {
  RamGuard._();

  // Conservative floor: never let available RAM drop below this after an
  // operation completes. Leaves headroom for the OS, launcher, and other
  // background apps on a 4GB device.
  static const int safetyFloorMb = 400;

  /// Reads current memory state from /proc/meminfo (Android/Linux only).
  /// Returns RamSnapshot.empty if unavailable (e.g. iOS, or permission
  /// denied) — callers should treat that as "unknown" and fail open only
  /// for non-destructive UI, never for a load-gating decision.
  static Future<RamSnapshot> read() async {
    try {
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

      // Same fallback as RamIndicator: some kernels don't expose
      // MemAvailable, so approximate with free+buffers+cached.
      final available =
          hasMemAvailable ? memAvailable : (memFree + buffers + cached);

      if (total == 0) return RamSnapshot.empty;

      return RamSnapshot(totalKb: total, availableKb: available);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('RamGuard: failed to read /proc/meminfo: $e');
      }
      return RamSnapshot.empty;
    }
  }

  /// Returns true if there's enough headroom to load something that will
  /// consume approximately [requiredMb] once resident, while keeping
  /// [safetyFloorMb] free afterward.
  ///
  /// If memory can't be read at all (non-Linux/Android, or read failure),
  /// this fails CLOSED (returns false) for load-gating purposes — better
  /// to block an operation and let the user override than to silently
  /// risk an OOM kill on an unknown device.
  static Future<bool> canLoad(int requiredMb, {bool failOpen = false}) async {
    final snap = await read();
    if (snap.totalKb == 0) return failOpen;
    return (snap.availableMb - requiredMb) >= safetyFloorMb;
  }

  /// Same as [canLoad] but throws a [RamGuardException] with a
  /// human-readable message when the check fails, so callers can surface
  /// it directly (e.g. in a SnackBar or dialog) without re-deriving the
  /// numbers themselves.
  static Future<void> ensureCanLoad(
    int requiredMb, {
    required String operation,
    bool failOpen = false,
  }) async {
    final snap = await read();
    if (snap.totalKb == 0) {
      if (failOpen) return;
      throw RamGuardException(
        'Could not determine available memory. Refusing to $operation '
        'to avoid a possible crash.',
        snapshot: snap,
      );
    }
    final projectedFreeMb = snap.availableMb - requiredMb;
    if (projectedFreeMb < safetyFloorMb) {
      throw RamGuardException(
        'Not enough free RAM to $operation. '
        '${snap.availableMb.toStringAsFixed(0)} MB available, '
        '~$requiredMb MB required '
        '(need ${safetyFloorMb}MB headroom afterward). '
        'Close other apps or choose a smaller model/context size.',
        snapshot: snap,
      );
    }
  }

  /// Rough heuristic for how much RAM a GGUF file will occupy once loaded:
  /// file size (weights) + a KV-cache overhead estimate driven by context
  /// size. This is intentionally generous (over-estimates) since being
  /// wrong in the "blocked a load that would've been fine" direction is
  /// far cheaper than being wrong in the OOM direction.
  static int estimateModelLoadMb({
    required int fileSizeBytes,
    required int contextSize,
  }) {
    final weightsMb = (fileSizeBytes / (1024 * 1024)).ceil();
    // Rough KV-cache cost scales with context size; ~0.5MB per 100 tokens
    // of context is a conservative placeholder for typical 3-8B models at
    // Q4 quantization. Larger models should override this via a
    // model-specific estimate if known.
    final kvOverheadMb = (contextSize / 100 * 0.5).ceil();
    return weightsMb + kvOverheadMb;
  }

  /// Convenience: is this device even in the "low-end" tier we're
  /// designing for? Used to decide default context size, whether to
  /// offer the "Advanced" unlocked settings section, etc.
  static Future<bool> isLowRamDevice() async {
    final snap = await read();
    if (snap.totalKb == 0) return true; // unknown -> assume constrained
    return snap.totalGb < 6.0;
  }
}

class RamGuardException implements Exception {
  final String message;
  final RamSnapshot snapshot;
  RamGuardException(this.message, {required this.snapshot});

  @override
  String toString() => message;
}
