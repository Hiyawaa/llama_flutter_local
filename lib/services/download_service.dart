import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Manages GGUF file downloads using Android's native DownloadWorker.
/// Downloads persist when app is backgrounded and show a notification
/// with a live progress bar.
class DownloadService {
  static bool _initialized = false;

  // Track active task IDs by filename so we can cancel them
  static final Map<String, String> _activeTasks = {};

  static Future<void> init() async {
    if (_initialized) return;

    // Configure notification shown in the status bar while downloading
    FileDownloader().configureNotification(
      running: const TaskNotification(
        'Downloading {filename}',
        '{progress}',
      ),
      complete: const TaskNotification(
        '{filename}',
        'Download complete ✓',
      ),
      error: const TaskNotification(
        '{filename}',
        'Download failed — tap to retry',
      ),
      paused: const TaskNotification(
        '{filename}',
        'Paused',
      ),
      progressBar: true,
      tapOpensFile: false,
    );

    // Allow up to 2 hours for large GGUF files
    await FileDownloader().configure(globalConfig: [
      (Config.requestTimeout, const Duration(hours: 2)),
    ]);

    _initialized = true;
  }

  /// Start or resume a download.
  /// [onProgress] receives 0.0–1.0, [onStatus] receives TaskStatus.
  static Future<void> startDownload(
    String url,
    String filename, {
    required void Function(double) onProgress,
    required void Function(TaskStatus) onStatus,
  }) async {
    await init();

    // Cancel any existing download for this file
    if (_activeTasks.containsKey(filename)) {
      await FileDownloader().cancelTasksWithIds([_activeTasks[filename]!]);
    }

    final task = DownloadTask(
      url: url,
      filename: filename,
      directory: 'models',
      baseDirectory: BaseDirectory.applicationDocuments,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
    );

    _activeTasks[filename] = task.taskId;

    // download() returns once the task finishes/fails.
    // While backgrounded, the notification keeps it alive.
    final result = await FileDownloader().download(
      task,
      onProgress: onProgress,
      onStatus: onStatus,
    );

    _activeTasks.remove(filename);

    // Surface final result
    onStatus(result.status);
  }

  static Future<void> cancel(String filename) async {
    final id = _activeTasks[filename];
    if (id != null) {
      await FileDownloader().cancelTasksWithIds([id]);
      _activeTasks.remove(filename);
    }
  }

  static Future<void> pause(String filename) async {
    final id = _activeTasks[filename];
    if (id != null) {
      await FileDownloader().pause(DownloadTask(
        taskId: id,
        url: '',
        filename: filename,
        directory: 'models',
        baseDirectory: BaseDirectory.applicationDocuments,
      ));
    }
  }

  /// Returns the full on-device path for a downloaded file
  static Future<String> localPath(String filename) async {
    final base = await getApplicationDocumentsDirectory();
    return p.join(base.path, 'models', filename);
  }

  /// Returns true if the file is already fully downloaded
  static Future<bool> isDownloaded(String filename, int expectedSize) async {
    final path = await localPath(filename);
    final file = File(path);
    if (!await file.exists()) return false;
    if (expectedSize <= 0) return true;
    final size = await file.length();
    return size == expectedSize;
  }

  /// List all downloaded GGUF files
  static Future<List<String>> listDownloaded() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'models'));
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.gguf'))
        .map((f) => f.path)
        .toList();
  }

  static bool isActive(String filename) => _activeTasks.containsKey(filename);
}
