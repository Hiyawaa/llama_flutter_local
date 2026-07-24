import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/app_theme.dart';
import '../models/chat_provider.dart';

/// Feature 3: RAG document management.
///
/// Deliberately supports only .txt and .pdf — the two formats a small
/// on-device embedding model can realistically make useful without OCR
/// or heavyweight document-layout parsing, both of which are non-starters
/// on a 4GB device.
class RagDocumentsScreen extends StatefulWidget {
  const RagDocumentsScreen({super.key});

  @override
  State<RagDocumentsScreen> createState() => _RagDocumentsScreenState();
}

class _RagDocumentsScreenState extends State<RagDocumentsScreen> {
  List<String> _docIds = [];
  bool _loading = true;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final provider = context.read<ChatProvider>();
    final ids = await provider.ragService.listDocIds();
    if (!mounted) return;
    setState(() {
      _docIds = ids;
      _loading = false;
    });
  }

  Future<String> _extractText(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.txt')) {
      return File(path).readAsString();
    }
    if (lower.endsWith('.pdf')) {
      // Pure-Dart PDF parsing (no native platform code, no OCR) — fine
      // for text-based PDFs, won't extract anything useful from scanned
      // image-only PDFs. That's an acceptable limitation for an offline,
      // low-RAM RAG feature rather than pulling in a full OCR pipeline.
      final bytes = await File(path).readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(doc).extractText();
      doc.dispose();
      return text;
    }
    throw StateError('Unsupported file type: $path');
  }

  Future<void> _pickAndIndex() async {
    final provider = context.read<ChatProvider>();
    if (provider.embeddingModelPath == null) {
      _showMessage(
        'No embedding model selected yet. Download a small embedding '
        'GGUF model (e.g. via the HuggingFace tab) and set it in Settings '
        'first.',
        isError: true,
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() => _statusMessage = 'Extracting text…');
    try {
      final text = await _extractText(path);
      if (text.trim().isEmpty) {
        _showMessage('No extractable text found in this file.', isError: true);
        setState(() => _statusMessage = null);
        return;
      }

      setState(() => _statusMessage = 'Unloading chat model, loading embedder…');
      final docId = p.basenameWithoutExtension(path);
      final count = await provider.indexRagDocument(
        docId: docId,
        sourceName: p.basename(path),
        text: text,
      );

      setState(() => _statusMessage = null);
      if (count == 0) {
        _showMessage(
          'Indexed 0 chunks — the embedding model may not support '
          'embeddings on this device/version, or RAM ran out mid-index.',
          isError: true,
        );
      } else {
        _showMessage('Indexed $count chunk(s) from ${p.basename(path)}.');
      }
      await _refresh();
    } catch (e) {
      setState(() => _statusMessage = null);
      _showMessage('Failed to index: $e', isError: true);
    }
  }

  void _showMessage(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.accentRed : null,
      ),
    );
  }

  Future<void> _delete(String docId) async {
    final provider = context.read<ChatProvider>();
    await provider.ragService.deleteDocument(docId);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          backgroundColor: AppTheme.bgBase,
          appBar: AppBar(
            title: const Text('RAG Documents'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _refresh,
                tooltip: 'Refresh',
              ),
            ],
          ),
          body: Column(
            children: [
              _ragToggleCard(provider),
              if (provider.ragBusy || _statusMessage != null) _busyBanner(),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: AppTheme.accentAmber))
                    : _docIds.isEmpty
                        ? const _EmptyDocs()
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _docIds.length,
                            itemBuilder: (_, i) => _DocCard(
                              docId: _docIds[i],
                              onDelete: () => _delete(_docIds[i]),
                            ),
                          ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: provider.ragBusy ? null : _pickAndIndex,
            backgroundColor: AppTheme.accentAmber,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('Add document'),
          ),
        );
      },
    );
  }

  Widget _ragToggleCard(ChatProvider provider) => Container(
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Use documents in chat',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  const Text(
                    'Each message will briefly swap out the chat model to '
                    'search your documents — this adds a few seconds of '
                    'delay per message but keeps memory use safe.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            Switch(
              value: provider.ragEnabled,
              onChanged: provider.ragBusy
                  ? null
                  : (v) => provider.setRagEnabled(v),
              activeThumbColor: AppTheme.accentAmber,
            ),
          ],
        ),
      );

  Widget _busyBanner() => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.accentBlue.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accentBlue.withAlpha(60)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentBlue),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _statusMessage ?? 'Working…',
                style: const TextStyle(color: AppTheme.accentBlue, fontSize: 12),
              ),
            ),
          ],
        ),
      );
}

class _DocCard extends StatelessWidget {
  final String docId;
  final VoidCallback onDelete;
  const _DocCard({required this.docId, required this.onDelete});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            const Icon(Icons.description_outlined, color: AppTheme.accentAmber, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(docId,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
                  overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppTheme.textMuted, size: 18),
              onPressed: onDelete,
            ),
          ],
        ),
      );
}

class _EmptyDocs extends StatelessWidget {
  const _EmptyDocs();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('📄', style: TextStyle(fontSize: 48)),
            SizedBox(height: 14),
            Text('No documents indexed yet',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text('Add a PDF or TXT file to search it from chat',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          ],
        ),
      );
}