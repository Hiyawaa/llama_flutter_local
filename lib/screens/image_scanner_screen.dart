import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/app_theme.dart';
import '../models/chat_provider.dart';

class ImageScannerScreen extends StatefulWidget {
  const ImageScannerScreen({super.key});

  @override
  State<ImageScannerScreen> createState() => _ImageScannerScreenState();
}

class _ImageScannerScreenState extends State<ImageScannerScreen> {
  final _picker = ImagePicker();
  final _promptCtrl = TextEditingController(
    text:
        'Analyze this image. If it contains a math problem, reconstruct it and solve it step by step using LaTeX.',
  );

  String? _imagePath;

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCamera() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (file == null) return;
    final cropped = await _crop(file.path);
    if (mounted) setState(() => _imagePath = cropped ?? file.path);
  }

  Future<void> _pickGallery() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return;
    final cropped = await _crop(file.path);
    if (mounted) setState(() => _imagePath = cropped ?? file.path);
  }

  Future<String?> _crop(String sourcePath) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: const Color(0xFF0F0F11),
          toolbarWidgetColor: const Color(0xFFF59E0B),
          backgroundColor: const Color(0xFF0F0F11),
          activeControlsWidgetColor: const Color(0xFFF59E0B),
          dimmedLayerColor: const Color(0xAA000000),
          cropFrameColor: const Color(0xFFF59E0B),
          cropGridColor: const Color(0x55F59E0B),
          cropFrameStrokeWidth: 3,
          showCropGrid: true,
          lockAspectRatio: false,
          hideBottomControls: false,
          initAspectRatio: CropAspectRatioPreset.original,
        ),
      ],
    );
    return cropped?.path;
  }

  Future<void> _sendToChat() async {
    final path = _imagePath;
    if (path == null) return;

    final provider = context.read<ChatProvider>();
    if (!provider.llama.isReady) {
      _showSnack('Load a vision model first.');
      return;
    }
    if (!provider.llama.hasVision) {
      _showSnack('Load a matching mmproj file before sending images.');
      return;
    }

    final prompt = _promptCtrl.text.trim().isEmpty
        ? 'Describe this image.'
        : _promptCtrl.text.trim();
    provider.sendMessage(prompt, imagePath: path);
    if (!mounted) return;
    Navigator.popUntil(context, (route) => route.isFirst);
    Navigator.pushNamed(context, '/chat');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _showPickSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(
                Icons.camera_alt_rounded,
                color: AppTheme.accentAmber,
              ),
              title: const Text(
                'Take photo',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickCamera();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_rounded,
                color: AppTheme.accentGreen,
              ),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickGallery();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final imagePath = _imagePath;

    return Scaffold(
      backgroundColor: AppTheme.bgBase,
      appBar: AppBar(
        title: const Text('Vision Chat'),
        actions: [
          if (imagePath != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'New image',
              onPressed: () => setState(() => _imagePath = null),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _VisionStatus(provider: provider),
            const SizedBox(height: 14),
            if (imagePath == null)
              _PickerArea(onCamera: _pickCamera, onGallery: _pickGallery)
            else
              _ImageComposer(
                imagePath: imagePath,
                promptCtrl: _promptCtrl,
                onChangeImage: _showPickSheet,
                onCrop: () async {
                  final cropped = await _crop(imagePath);
                  if (cropped != null && mounted) {
                    setState(() => _imagePath = cropped);
                  }
                },
                onSend: provider.isGenerating ? null : _sendToChat,
              ),
          ],
        ),
      ),
    );
  }
}

class _VisionStatus extends StatelessWidget {
  final ChatProvider provider;
  const _VisionStatus({required this.provider});

  @override
  Widget build(BuildContext context) {
    final ready = provider.llama.isReady;
    final hasVision = provider.llama.hasVision;
    final text = !ready
        ? 'Load a GGUF vision model first.'
        : hasVision
            ? 'Vision ready: ${provider.llama.loadedMmprojPath!.split('/').last}'
            : 'Model loaded without mmproj. Download/load the matching vision file.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasVision
              ? AppTheme.accentGreen.withValues(alpha: 0.35)
              : AppTheme.borderColor,
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasVision ? Icons.visibility_rounded : Icons.info_outline_rounded,
            color: hasVision ? AppTheme.accentGreen : AppTheme.accentAmber,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerArea extends StatelessWidget {
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  const _PickerArea({required this.onCamera, required this.onGallery});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Column(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppTheme.bgSurface,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: const Icon(
                Icons.image_search_rounded,
                size: 42,
                color: AppTheme.accentAmber,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'Ask the local vision model',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Send the image directly through the loaded mmproj projector.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 30),
            Row(
              children: [
                Expanded(
                  child: _BigButton(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    color: AppTheme.accentAmber,
                    onTap: onCamera,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _BigButton(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    color: AppTheme.accentGreen,
                    onTap: onGallery,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _ImageComposer extends StatelessWidget {
  final String imagePath;
  final TextEditingController promptCtrl;
  final VoidCallback onChangeImage;
  final VoidCallback onCrop;
  final VoidCallback? onSend;

  const _ImageComposer({
    required this.imagePath,
    required this.promptCtrl,
    required this.onChangeImage,
    required this.onCrop,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.file(File(imagePath), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _SmallButton(
                icon: Icons.swap_horiz_rounded,
                label: 'Change',
                onTap: onChangeImage,
              ),
              const SizedBox(width: 8),
              _SmallButton(
                  icon: Icons.crop_rounded, label: 'Crop', onTap: onCrop),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: promptCtrl,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'Ask about the image...',
              hintStyle: const TextStyle(color: AppTheme.textMuted),
              filled: true,
              fillColor: AppTheme.bgSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.accentAmber),
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
            label: const Text('Send to chat'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      );
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BigButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.textSecondary,
          side: const BorderSide(color: AppTheme.borderColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
}
