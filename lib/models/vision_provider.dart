import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/vision_service.dart';

export '../services/vision_service.dart' show VisionStatus;

enum VisionGenStatus { idle, generating, done, error }

class VisionMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  VisionMessage({required this.role, required this.content});
}

class VisionProvider extends ChangeNotifier {
  final VisionService _svc = VisionService();

  String? _imagePath;
  VisionGenStatus _genStatus = VisionGenStatus.idle;
  String? _error;

  final List<VisionMessage> _messages = [];

  // Saved model/mmproj paths
  String? _savedModelPath;
  String? _savedMmprojPath;

  // True while the saved model is being restored automatically on startup,
  // so the UI can show a quiet "restoring..." state instead of flashing
  // the "no model loaded" banner before disappearing again.
  bool _isAutoLoading = false;

  VisionService get service => _svc;
  String? get imagePath => _imagePath;
  VisionGenStatus get genStatus => _genStatus;
  String? get error => _error;
  List<VisionMessage> get messages => List.unmodifiable(_messages);
  bool get isGenerating => _genStatus == VisionGenStatus.generating;
  String? get savedModelPath => _savedModelPath;
  String? get savedMmprojPath => _savedMmprojPath;
  bool get isAutoLoading => _isAutoLoading;

  VisionProvider() {
    _loadSaved();
  }

  /// Restore the previously loaded vision model so the user doesn't have to
  /// re-pick the .gguf files every time the app restarts.
  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    _savedModelPath = p.getString('vision_model_path');
    _savedMmprojPath = p.getString('vision_mmproj_path');
    notifyListeners();

    final modelPath = _savedModelPath;
    final mmprojPath = _savedMmprojPath;
    if (modelPath == null || mmprojPath == null) return;

    // The files may have been deleted/moved since they were last loaded
    // (e.g. via the "Delete model" action on the model picker screen).
    // Guard against trying to load a missing file.
    if (!await File(modelPath).exists() || !await File(mmprojPath).exists()) {
      return;
    }

    _isAutoLoading = true;
    notifyListeners();
    try {
      await _svc.loadModel(modelPath, mmprojPath);
    } catch (e) {
      _error = 'Failed to restore vision model: $e';
    }
    _isAutoLoading = false;
    notifyListeners();
  }

  Future<void> _savePaths(String model, String mmproj) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('vision_model_path', model);
    await p.setString('vision_mmproj_path', mmproj);
    _savedModelPath = model;
    _savedMmprojPath = mmproj;
  }

  Future<void> loadModel(String modelPath, String mmprojPath) async {
    notifyListeners();
    await _svc.loadModel(modelPath, mmprojPath);
    await _savePaths(modelPath, mmprojPath);
    notifyListeners();
  }

  void setImage(String path) {
    _imagePath = path;
    _messages.clear();
    notifyListeners();
  }

  void clearImage() {
    _imagePath = null;
    _messages.clear();
    _genStatus = VisionGenStatus.idle;
    notifyListeners();
  }

  Future<void> analyzeImage(
      {String prompt = 'Describe this image in detail.'}) async {
    if (_imagePath == null || !_svc.isReady) return;
    await _sendMessage(prompt, isFirst: true);
  }

  Future<void> sendFollowUp(String message) async {
    if (_imagePath == null || !_svc.isReady) return;
    await _sendMessage(message, isFirst: false);
  }

  Future<void> _sendMessage(String message, {required bool isFirst}) async {
    _messages.add(VisionMessage(role: 'user', content: message));
    _genStatus = VisionGenStatus.generating;
    _error = null;
    notifyListeners();

    final aiMsg = VisionMessage(role: 'assistant', content: '');
    _messages.add(aiMsg);

    try {
      if (isFirst && _messages.length <= 2) {
        // First message — straightforward analyze
        await for (final token in _svc.analyzeImage(
          _imagePath!,
          prompt: message,
        )) {
          (aiMsg as dynamic).content; // ignore: we mutate below
          _messages[_messages.length - 1] = VisionMessage(
            role: 'assistant',
            content: _messages.last.content + token,
          );
          notifyListeners();
        }
      } else {
        // Follow-up — pass full history
        final history = _messages
            .sublist(0, _messages.length - 1)
            .map((m) => {'role': m.role, 'content': m.content})
            .toList();

        await for (final token in _svc.chatWithImage(
          _imagePath!,
          history,
          message,
        )) {
          _messages[_messages.length - 1] = VisionMessage(
            role: 'assistant',
            content: _messages.last.content + token,
          );
          notifyListeners();
        }
      }
      _genStatus = VisionGenStatus.done;
    } catch (e) {
      _messages[_messages.length - 1] = VisionMessage(
        role: 'assistant',
        content: 'Error: $e',
      );
      _genStatus = VisionGenStatus.error;
      _error = e.toString();
    }
    notifyListeners();
  }

  void stop() {
    _svc.stop();
    _genStatus = VisionGenStatus.idle;
    notifyListeners();
  }

  void clearMessages() {
    _messages.clear();
    _genStatus = VisionGenStatus.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }
}
