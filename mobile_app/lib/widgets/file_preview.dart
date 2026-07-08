import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import '../models/file_utils.dart';
import '../models/print_file.dart';

/// Supported preview categories.
enum _PreviewType { pdf, image, text, unsupported }

/// Standalone file-preview component.
///
/// Pushes a full-screen page that renders PDFs, images, or plain text
/// depending on the file extension.
///
/// ```dart
/// FilePreview.show(context, file);
/// ```
class FilePreview extends StatelessWidget {
  final PrintFile file;

  const FilePreview({super.key, required this.file});

  /// Convenience: push a full-screen preview route.
  static Future<void> show(BuildContext context, PrintFile file) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => FilePreview(file: file)));
  }

  /// Returns just the preview body widget (no Scaffold).
  /// Use this to embed the preview inline in other pages.
  static Widget body(PrintFile file) => _FilePreviewBody(file: file);

  // ─── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    final ext = file.storedName.split('.').last.toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          file.displayName,
          style: const TextStyle(fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  ext,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: theme.onSurface.withValues(alpha: 0.5),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) => _FilePreviewBody(file: file);
}

/// The preview body — renders the file content without a Scaffold.
/// Used by both [FilePreview] (full-screen) and [FilePreview.body] (inline).
class _FilePreviewBody extends StatelessWidget {
  final PrintFile file;
  const _FilePreviewBody({required this.file});

  _PreviewType get _type {
    final ext = file.storedName.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => _PreviewType.pdf,
      'jpg' ||
      'jpeg' ||
      'png' ||
      'webp' ||
      'bmp' ||
      'gif' => _PreviewType.image,
      'txt' ||
      'md' ||
      'markdown' ||
      'log' ||
      'csv' ||
      'json' ||
      'xml' => _PreviewType.text,
      _ => _PreviewType.unsupported,
    };
  }

  @override
  Widget build(BuildContext context) {
    final localPath = file.localPath;
    if (localPath == null || !File(localPath).existsSync()) {
      return const _ErrorState(
        icon: Icons.folder_off_outlined,
        message: '本地文件不可用',
      );
    }
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    return switch (_type) {
      _PreviewType.pdf =>
        isWindows
            ? _UnsupportedPreview(file: file)
            : _PdfPreview(path: localPath),
      _PreviewType.image => _ImagePreview(path: localPath),
      _PreviewType.text => _TextPreview(path: localPath),
      _PreviewType.unsupported => _UnsupportedPreview(file: file),
    };
  }
}

// ─── PDF Preview ─────────────────────────────────────────────────

class _PdfPreview extends StatefulWidget {
  final String path;
  const _PdfPreview({required this.path});

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  int _totalPages = 0;
  int _currentPage = 0;
  bool _loading = true;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;

    if (_error != null) {
      return _ErrorState(icon: Icons.error_outline_rounded, message: _error!);
    }

    return Stack(
      children: [
        PDFView(
          filePath: widget.path,
          enableSwipe: true,
          swipeHorizontal: false,
          autoSpacing: true,
          pageFling: true,
          pageSnap: true,
          fitPolicy: FitPolicy.BOTH,
          backgroundColor: theme.surface,
          onRender: (pages) {
            setState(() {
              _totalPages = pages ?? 0;
              _loading = false;
            });
          },
          onError: (error) {
            setState(() {
              _error = error.toString();
              _loading = false;
            });
          },
          onPageError: (page, error) {
            debugPrint('PDF page $page error: $error');
          },
          onPageChanged: (page, total) {
            setState(() {
              _currentPage = page ?? 0;
              _totalPages = total ?? 0;
            });
          },
        ),

        // Loading indicator
        if (_loading) const Center(child: CircularProgressIndicator()),

        // Page indicator
        if (!_loading && _totalPages > 1)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_currentPage + 1} / $_totalPages',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.onSurface,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Image Preview ───────────────────────────────────────────────

class _ImagePreview extends StatelessWidget {
  final String path;
  const _ImagePreview({required this.path});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5.0,
      child: Center(
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const _ErrorState(
            icon: Icons.broken_image_outlined,
            message: '加载图片失败',
          ),
        ),
      ),
    );
  }
}

// ─── Text Preview ────────────────────────────────────────────────

class _TextPreview extends StatefulWidget {
  final String path;
  const _TextPreview({required this.path});

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  String? _content;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadText();
  }

  Future<void> _loadText() async {
    try {
      final content = await File(widget.path).readAsString();
      if (mounted) {
        setState(() {
          _content = content;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorState(icon: Icons.error_outline_rounded, message: _error!);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        _content ?? '',
        style: TextStyle(
          fontSize: 14,
          height: 1.7,
          fontFamily: 'monospace',
          color: theme.onSurface,
        ),
      ),
    );
  }
}

// ─── Unsupported / Fallback ──────────────────────────────────────

class _UnsupportedPreview extends StatelessWidget {
  final PrintFile file;
  const _UnsupportedPreview({required this.file});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    final ext = file.storedName.split('.').last.toUpperCase();

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 76,
            decoration: BoxDecoration(
              color: theme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Image.asset(
                fileIconForName(file.storedName),
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            file.displayName,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: theme.onSurface,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '.$ext · ${file.formattedSize}',
            style: TextStyle(
              fontSize: 13,
              color: theme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Error State ─────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _ErrorState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: theme.error.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: theme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
