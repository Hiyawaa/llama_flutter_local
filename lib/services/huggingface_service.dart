import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ── Data models ──────────────────────────────────────────────────────────────

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
  final int size; // bytes
  final String rfilename;

  HFFile({required this.filename, required this.size, required this.rfilename});

  bool get isGguf => filename.toLowerCase().endsWith('.gguf');

  String get sizeLabel {
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // Quantization label extracted from filename
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
      'F16',
      'F32'
    ]) {
      if (name.contains(q)) return q;
    }
    return '';
  }

  factory HFFile.fromJson(Map<String, dynamic> j) => HFFile(
        filename: j['rfilename'] as String? ?? '',
        rfilename: j['rfilename'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
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

  /// Search for GGUF models on Hugging Face
  Future<List<HFModel>> searchModels(String query, {int limit = 20}) async {
    final uri = Uri.parse('$_apiBase/models').replace(queryParameters: {
      'search': query.isEmpty ? 'gguf' : query,
      'filter': 'gguf',
      'sort': 'downloads',
      'limit': '$limit',
    });

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

  /// Get the list of GGUF files for a specific model
  Future<List<HFFile>> getModelFiles(String modelId) async {
    final uri = Uri.parse('$_apiBase/models/$modelId');
    final response = await _client.get(uri, headers: {
      'Accept': 'application/json'
    }).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch model info: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final siblings = data['siblings'] as List<dynamic>? ?? [];

    return siblings
        .map((f) => HFFile.fromJson(f as Map<String, dynamic>))
        .where((f) => f.isGguf)
        .toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));
  }

  /// Download a GGUF file with progress reporting.
  /// Saves to the app's external files directory (no storage permission needed).
  Stream<DownloadProgress> downloadFile(
    String modelId,
    HFFile file,
  ) async* {
    final url = '$_base/$modelId/resolve/main/${file.rfilename}';
    final savePath = await _localPath(file.filename);

    // If already downloaded, skip
    final existing = File(savePath);
    if (await existing.exists()) {
      final size = await existing.length();
      if (size == file.size || file.size == 0) {
        yield DownloadProgress(
          filename: file.filename,
          received: size,
          total: size,
          isDone: true,
        );
        return;
      }
      // Partial file — delete and restart
      await existing.delete();
    }

    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request).timeout(
          const Duration(seconds: 30),
        );

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
      // Clean up partial file
      if (await File(savePath).exists()) await File(savePath).delete();
      yield DownloadProgress(
        filename: file.filename,
        received: received,
        total: total,
        error: e.toString(),
      );
    }
  }

  /// List already-downloaded GGUF files
  Future<List<String>> localModels() async {
    final dir = Directory(await _localDir());
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    return files
        .whereType<File>()
        .where((f) => f.path.endsWith('.gguf'))
        .map((f) => f.path)
        .toList();
  }

  Future<String> _localDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final models = Directory(p.join(dir.path, 'models'));
    if (!await models.exists()) await models.create(recursive: true);
    return models.path;
  }

  Future<String> _localPath(String filename) async {
    return p.join(await _localDir(), filename);
  }

  void dispose() => _client.close();
}
