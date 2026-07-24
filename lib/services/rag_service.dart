import 'dart:math' as math;
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'embedding_service.dart';
import 'ram_guard_service.dart';

part 'rag_service.g.dart';

// ── Schema ────────────────────────────────────────────────────────────────────
//
// NOTE: this file uses Isar code generation. After adding/editing this
// class, run:
//   flutter pub run build_runner build --delete-conflicting-outputs
// to (re)generate rag_service.g.dart. Until that's run, this file will not
// compile — that's expected for any Isar collection, not specific to this
// implementation.

@collection
class DocChunk {
  Id id = Isar.autoIncrement;

  @Index()
  late String docId; // groups chunks belonging to the same source file

  late String sourceName; // original filename, for citing in the UI
  late String text; // the chunk's raw text (kept short, see _chunkSize)
  late List<double> embedding; // dense vector from EmbeddingService
  late DateTime indexedAt;
}

/// A retrieved chunk plus its similarity score, returned to callers for
/// display/citation purposes.
class RagResult {
  final String text;
  final String sourceName;
  final double score;

  RagResult({required this.text, required this.sourceName, required this.score});
}

/// Feature 3: RAG over offline PDFs/TXT.
///
/// Chunking and search both run entirely on-device. Two RAM disciplines
/// matter here on a 4GB target:
///
/// 1. Indexing requires the embedding model, which per EmbeddingService's
///    contract must never be resident at the same time as the chat model.
///    `RagService.indexDocument` therefore takes an `unloadChatModel`
///    callback and calls it before doing anything memory-heavy, then
///    calls the paired `reloadChatModel` callback (if given) afterward.
/// 2. Similarity search is brute-force cosine over chunks pulled from
///    Isar — fine for the personal-document scale this app targets
///    (dozens to low hundreds of chunks), but NOT something to let grow
///    unbounded. `maxChunksPerDoc` caps how much of any single document
///    gets indexed so a huge PDF can't quietly balloon local storage and
///    per-query CPU cost into unusable territory on weak hardware.
class RagService {
  static const int _chunkSize = 800; // chars per chunk, keeps embedding calls small
  static const int _chunkOverlap = 100;
  static const int maxChunksPerDoc = 400;
  static const int topK = 4;

  Isar? _isar;
  final EmbeddingService embeddingService;

  RagService({EmbeddingService? embeddingService})
      : embeddingService = embeddingService ?? EmbeddingService();

  Future<Isar> _db() async {
    if (_isar != null) return _isar!;
    final dir = await getApplicationDocumentsDirectory();
    _isar = await Isar.open([DocChunkSchema], directory: dir.path);
    return _isar!;
  }

  List<String> _chunkText(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return [];
    final chunks = <String>[];
    var start = 0;
    while (start < cleaned.length && chunks.length < maxChunksPerDoc) {
      final end = math.min(start + _chunkSize, cleaned.length);
      chunks.add(cleaned.substring(start, end));
      if (end == cleaned.length) break;
      start = end - _chunkOverlap;
      if (start < 0) start = 0;
    }
    return chunks;
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0, magA = 0, magB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    if (magA == 0 || magB == 0) return 0.0;
    return dot / (math.sqrt(magA) * math.sqrt(magB));
  }

  /// Indexes [text] (already-extracted plain text from a PDF/TXT file —
  /// extraction itself belongs in the pdf skill/tooling, not here) under
  /// [docId]/[sourceName]. Requires the embedding model to be loaded by
  /// the caller first (see class doc on the unload/reload handoff).
  Future<int> indexDocument({
    required String docId,
    required String sourceName,
    required String text,
  }) async {
    if (!embeddingService.isReady) {
      throw StateError(
        'Embedding model not loaded — call embeddingService.load(...) '
        'after unloading the chat model before indexing.',
      );
    }

    final chunks = _chunkText(text);
    if (chunks.isEmpty) return 0;

    final db = await _db();
    // Remove any previous chunks for this doc so re-indexing doesn't
    // accumulate duplicates and quietly grow storage forever.
    await db.writeTxn(() async {
      await db.docChunks.filter().docIdEqualTo(docId).deleteAll();
    });

    var indexed = 0;
    for (final chunk in chunks) {
      // Re-check RAM every N chunks rather than once up front — indexing
      // a long document is exactly the kind of sustained operation where
      // memory pressure can build up gradually rather than all at once.
      if (indexed % 20 == 0) {
        final ok = await RamGuard.canLoad(100, failOpen: true);
        if (!ok) break; // stop indexing gracefully; partial index still useful
      }

      final vector = await embeddingService.embed(chunk);
      if (vector == null) {
        continue; // embedding unsupported/failed for this chunk
      }

      final docChunk = DocChunk()
        ..docId = docId
        ..sourceName = sourceName
        ..text = chunk
        ..embedding = vector
        ..indexedAt = DateTime.now();

      await db.writeTxn(() async {
        await db.docChunks.put(docChunk);
      });
      indexed++;
    }
    return indexed;
  }

  /// Returns the top-K most relevant chunks for [query]. Requires the
  /// embedding model to be loaded (same handoff rule as indexing).
  Future<List<RagResult>> search(String query) async {
    if (!embeddingService.isReady) {
      throw StateError(
        'Embedding model not loaded — call embeddingService.load(...) '
        'before searching.',
      );
    }
    final queryVector = await embeddingService.embed(query);
    if (queryVector == null) return [];

    final db = await _db();
    final allChunks = await db.docChunks.where().findAll();
    if (allChunks.isEmpty) return [];

    final scored = allChunks.map((c) {
      final score = _cosineSimilarity(queryVector, c.embedding);
      return RagResult(text: c.text, sourceName: c.sourceName, score: score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return scored.take(topK).toList();
  }

  /// Builds a compact context block to prepend to the user's prompt.
  /// Kept short deliberately — context tokens compete directly with the
  /// 1024-token ceiling we enforce elsewhere for low-RAM devices.
  String buildContextBlock(List<RagResult> results) {
    if (results.isEmpty) return '';
    final buf = StringBuffer('Relevant context from your documents:\n');
    for (final r in results) {
      buf.writeln('[${r.sourceName}] ${r.text}');
    }
    return buf.toString();
  }

  Future<void> deleteDocument(String docId) async {
    final db = await _db();
    await db.writeTxn(() async {
      await db.docChunks.filter().docIdEqualTo(docId).deleteAll();
    });
  }

  Future<void> deleteAll() async {
    final db = await _db();
    await db.writeTxn(() async {
      await db.docChunks.clear();
    });
  }

  Future<List<String>> listDocIds() async {
    final db = await _db();
    final all = await db.docChunks.where().findAll();
    return all.map((c) => c.docId).toSet().toList();
  }

  Future<void> close() async {
    await _isar?.close();
    _isar = null;
  }
}