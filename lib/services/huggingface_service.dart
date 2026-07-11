import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ── Data models ───────────────────────────────────────────────────────────────

class HFModel {
  final String id;
  final int downloads;
  final int likes;
  final String lastModified;
  final List<String> tags;

  HFModel({
    required this.id,
    required this.downloads,
    required this.likes,
    required this.lastModified,
    required this.tags,
  });

  String get name => id.contains('/') ? id.split('/').last : id;
  String get author => id.contains('/') ? id.split('/').first : '';

  factory HFModel.fromJson(Map<String, dynamic> j) => HFModel(
        id: j['id'] as String? ?? '',
        downloads: j['downloads'] as int? ?? 0,
        likes: j['likes'] as int? ?? 0,
        lastModified: j['lastModified'] as String? ?? '',
        tags: (j['tags'] as List<dynamic>? ?? [])
            .map((t) => t.toString())
            .toList(),
      );
}

class HFFile {
  final String filename;
  final int size; // bytes — resolved from lfs.size for LFS files
  final String rfilename;

  HFFile({required this.filename, required this.size, required this.rfilename});

  bool get isGguf => filename.toLowerCase().endsWith('.gguf');

  /// True if this is a vision projector file rather than a main model — these
  /// always need to be downloaded alongside the matching main model for
  /// image support to work.
  bool get isMmproj => filename.toLowerCase().contains('mmproj');

  String get sizeLabel {
    if (size <= 0) {
      return 'Unknown size';
    }
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get quantLabel {
    final name = filename.toUpperCase();
    for (final q in [
      'Q8_0',
      'Q6_K',
      'Q5_K_M',
      'Q5_K_S',
      'Q5_0',
      'Q4_K_M',
      'Q4_K_S',
      'Q4_0',
      'Q3_K_M',
      'Q3_K_S',
      'Q2_K',
      'IQ4_XS',
      'IQ3_XS',
      'F16',
      'F32',
    ]) {
      if (name.contains(q)) return q;
    }
    return '';
  }

  // FIX: GGUF files are stored with Git LFS.
  // The top-level 'size' in siblings is the LFS *pointer* size (~130 bytes),
  // NOT the actual file size. The real size lives in siblings[].lfs.size —
  // but that 'lfs' object is only present in the API response at all if the
  // request explicitly asked for it (see getModelFiles's blobs=true below).
  // Without that, every file here silently has no size info whatsoever,
  // not just a wrong one — which is why every file was showing "Unknown
  // size" regardless of what it actually was.
  factory HFFile.fromJson(Map<String, dynamic> j) {
    final lfs = j['lfs'] as Map<String, dynamic>?;
    final lfsSize = (lfs?['size'] as num?)?.toInt();
    final rawSize = (j['size'] as num?)?.toInt() ?? 0;

    // Prefer lfs.size; fall back to raw size only if lfs is absent
    // (non-LFS small files, e.g. tokenizer configs).
    final size = (lfsSize != null && lfsSize > 0) ? lfsSize : rawSize;

    return HFFile(
      filename: j['rfilename'] as String? ?? '',
      rfilename: j['rfilename'] as String? ?? '',
      size: size,
    );
  }
}

// ── Download progress ─────────────────────────────────────────────────────────

class DownloadProgress {
  final String filename;
  final int received;
  final int total;
  final bool isDone;
  final String? error;

  DownloadProgress({
    required this.filename,
    required this.received,
    required this.total,
    this.isDone = false,
    this.error,
  });

  double get fraction => total > 0 ? received / total : 0;
  bool get hasError => error != null;
}

// ── Service ───────────────────────────────────────────────────────────────────

class HuggingFaceService {
  static const _base = 'https://huggingface.co';
  static const _apiBase = 'https://huggingface.co/api';

  final http.Client _client = http.Client();

  Future<List<HFModel>> searchModels(String query, {int limit = 20}) async {
    final uri = Uri.parse('$_apiBase/models').replace(
      queryParameters: {
        'search': query.isEmpty ? 'gguf' : query,
        'filter': 'gguf',
        'sort': 'downloads',
        'limit': '$limit',
      },
    );

    final response = await _client.get(uri, headers: {
      'Accept': 'application/json'
    }).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('HF API error: ${response.statusCode}');
    }

    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((j) => HFModel.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<List<HFFile>> getModelFiles(String modelId) async {
    // FIX: 'blobs=true' is required for the Hub API to include each
    // sibling's 'lfs' object (which carries the real byte size). Without
    // it, siblings come back as bare {"rfilename": "..."} with no size
    // field at all — that's the actual root cause of every file always
    // showing "Unknown size" regardless of its real size.
    final uri = Uri.parse('$_apiBase/models/$modelId').replace(
      queryParameters: {'blobs': 'true'},
    );
    final response = await _client.get(uri, headers: {
      'Accept': 'application/json'
    }).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch model info: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final siblings = data['siblings'] as List<dynamic>? ?? [];

    var files = siblings
        .map((f) => HFFile.fromJson(f as Map<String, dynamic>))
        .where((f) => f.isGguf)
        .toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));

    // Defensive fallback: if the Hub ever changes behavior and blobs=true
    // stops returning lfs data (or the repo's files aren't stored via LFS
    // for some reason), fetch each file's real size individually via a
    // HEAD request rather than silently showing "Unknown size" for
    // everything. This only fires for files that still came back with
    // size <= 0 after the primary request, so it doesn't add overhead in
    // the normal case.
    final missingSizes = files.where((f) => f.size <= 0).toList();
    if (missingSizes.isNotEmpty) {
      final resolved = await Future.wait(missingSizes.map((f) async {
        final size = await _headSize(modelId, f.rfilename);
        return size > 0
            ? HFFile(filename: f.filename, rfilename: f.rfilename, size: size)
            : f;
      }));
      final byName = {for (final f in resolved) f.filename: f};
      files = files.map((f) => byName[f.filename] ?? f).toList();
    }

    return files;
  }

  /// Resolves a file's real size via a HEAD request's Content-Length,
  /// following redirects (the resolve/main URL 302s to the actual CDN
  /// blob URL, which is where Content-Length reflects the true file
  /// size for LFS-backed files).
  Future<int> _headSize(String modelId, String rfilename) async {
    try {
      final url = '$_base/$modelId/resolve/main/$rfilename';
      final request = http.Request('HEAD', Uri.parse(url))
        ..followRedirects = true;
      final response =
          await _client.send(request).timeout(const Duration(seconds: 10));
      // Drain the (empty) response stream so the connection is released.
      await response.stream.drain();
      return response.contentLength ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Stream<DownloadProgress> downloadFile(String modelId, HFFile file) async* {
    final url = '$_base/$modelId/resolve/main/${file.rfilename}';
    final savePath = await _localPath(file.filename);

    final existing = File(savePath);
    if (await existing.exists()) {
      final sz = await existing.length();
      if (file.size > 0 && sz == file.size) {
        yield DownloadProgress(
          filename: file.filename,
          received: sz,
          total: sz,
          isDone: true,
        );
        return;
      }
      await existing.delete();
    }

    final request = http.Request('GET', Uri.parse(url));
    final response =
        await _client.send(request).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      yield DownloadProgress(
        filename: file.filename,
        received: 0,
        total: file.size,
        error: 'HTTP ${response.statusCode}',
      );
      return;
    }

    final total = response.contentLength ?? file.size;
    int received = 0;
    final sink = File(savePath).openWrite();

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        yield DownloadProgress(
          filename: file.filename,
          received: received,
          total: total,
        );
      }
      await sink.flush();
      await sink.close();
      yield DownloadProgress(
        filename: file.filename,
        received: received,
        total: total,
        isDone: true,
      );
    } catch (e) {
      await sink.close();
      if (await File(savePath).exists()) await File(savePath).delete();
      yield DownloadProgress(
        filename: file.filename,
        received: received,
        total: total,
        error: e.toString(),
      );
    }
  }

  Future<List<String>> localModels() async {
    final dir = Directory(await _localDir());
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    return files
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.gguf') &&
              !p.basename(f.path).toLowerCase().contains('mmproj'),
        )
        .map((f) => f.path)
        .toList();
  }

  Future<String> _localDir() async {
    final base = await getApplicationDocumentsDirectory();
    final models = Directory(p.join(base.path, 'models'));
    if (!await models.exists()) await models.create(recursive: true);
    return models.path;
  }

  Future<String> _localPath(String filename) async =>
      p.join(await _localDir(), filename);

  void dispose() => _client.close();
}