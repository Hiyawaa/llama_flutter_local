import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'ram_guard_service.dart';
import 'llama_service.dart';

/// Result of an attempted KV-cache restore, so the caller (ChatProvider)
/// knows whether it got a fast binary-session restore or needs to replay
/// conversation history through the model the slow way.
enum KvRestoreOutcome { restoredFromSession, needsReplay, failed }

/// Feature 1: KV-Cache persistence.
///
/// On a 4GB device, re-processing a long conversation's history on every
/// resume is slow and briefly memory-hungry (prompt processing allocates
/// scratch buffers proportional to context size). Saving/restoring the
/// raw KV-cache session avoids that reprocessing entirely — IF the
/// underlying llamadart engine supports it (see llama_service.dart's
/// dynamic-dispatch probe). Where it isn't supported, this service still
/// provides value by persisting the plain conversation text, which
/// ChatProvider can replay through the normal `history` parameter — no
/// faster, but keeps the same save/restore call sites this class expects.
class KvCacheService {
  static const _dir = 'kv_cache';

  // Session binary files can be very large (proportional to context size
  // and layer count). A true free-disk-space check requires a platform
  // channel this project doesn't have; RamGuard's RAM check plus letting
  // a failed write surface as an exception is the practical backstop
  // here instead.

  Future<Directory> _cacheDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, _dir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _sessionFileFor(String sessionId) => '$sessionId.session.bin';
  String _metaFileFor(String sessionId) => '$sessionId.meta.json';

  /// Saves the current model session for [sessionId], if the engine
  /// supports native session serialization. Returns true on success.
  /// Always RAM-gated first — writing a multi-hundred-MB session file
  /// while the device is already under memory pressure is a good way to
  /// trigger the exact OOM this app is trying to avoid.
  Future<bool> saveSession(LlamaService llama, String sessionId) async {
    final ok = await RamGuard.canLoad(150, failOpen: false);
    if (!ok) return false;

    final dir = await _cacheDir();
    final path = p.join(dir.path, _sessionFileFor(sessionId));
    final saved = await llama.trySaveSessionTo(path);

    await _writeMeta(sessionId, hasNativeSession: saved);
    return saved;
  }

  /// Attempts to restore a previously saved session. Returns which path
  /// succeeded so ChatProvider can decide whether it still needs to feed
  /// history through `chat()` manually.
  Future<KvRestoreOutcome> restoreSession(
    LlamaService llama,
    String sessionId,
  ) async {
    final dir = await _cacheDir();
    final sessionPath = p.join(dir.path, _sessionFileFor(sessionId));
    final sessionFile = File(sessionPath);

    if (!await sessionFile.exists()) {
      return KvRestoreOutcome.needsReplay;
    }

    // Re-check RAM before loading a potentially large session blob back
    // into memory — the same guardrail logic as a fresh model load.
    final sizeBytes = await sessionFile.length();
    final estimateMb = (sizeBytes / (1024 * 1024)).ceil() + 100;
    final canLoad = await RamGuard.canLoad(estimateMb);
    if (!canLoad) {
      return KvRestoreOutcome.failed;
    }

    final ok = await llama.tryLoadSessionFrom(sessionPath);
    return ok
        ? KvRestoreOutcome.restoredFromSession
        : KvRestoreOutcome.needsReplay;
  }

  Future<void> deleteSession(String sessionId) async {
    final dir = await _cacheDir();
    final sessionFile = File(p.join(dir.path, _sessionFileFor(sessionId)));
    final metaFile = File(p.join(dir.path, _metaFileFor(sessionId)));
    if (await sessionFile.exists()) await sessionFile.delete();
    if (await metaFile.exists()) await metaFile.delete();
  }

  Future<void> deleteAll() async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Total disk space currently used by saved sessions, so Settings can
  /// show the user something concrete and offer to clear it.
  Future<int> totalSizeBytes() async {
    final dir = await _cacheDir();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> _writeMeta(String sessionId,
      {required bool hasNativeSession}) async {
    final dir = await _cacheDir();
    final metaFile = File(p.join(dir.path, _metaFileFor(sessionId)));
    final digest = sha256.convert(utf8.encode(sessionId)).toString();
    await metaFile.writeAsString(jsonEncode({
      'sessionId': sessionId,
      'hash': digest,
      'hasNativeSession': hasNativeSession,
      'savedAt': DateTime.now().toIso8601String(),
    }));
  }
}
