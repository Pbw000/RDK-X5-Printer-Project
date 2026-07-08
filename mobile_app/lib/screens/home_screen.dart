import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/print_file.dart';
import '../services/api_service.dart';
import '../services/pending_file_store.dart';
import '../widgets/file_preview.dart';
import '../widgets/location_bottom_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService.instance;
  final _store = PendingFileStore.instance;
  final _uploadProgress = <String, double>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _store.loadLocations();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        // ── Header (pinned, shrinks on scroll) ────────
        SliverAppBar(
          pinned: true,
          expandedHeight: 72,
          toolbarHeight: 52,
          automaticallyImplyLeading: false,
          backgroundColor: theme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          flexibleSpace: LayoutBuilder(
            builder: (context, constraints) {
              final topPadding = MediaQuery.of(context).padding.top;
              final available = constraints.biggest.height - topPadding;
              const maxH = 72.0;
              const minH = 52.0;
              final t = ((available - minH) / (maxH - minH)).clamp(0.0, 1.0);
              final fontSize = 20.0 + 8.0 * t;
              final top = topPadding + 12.0 + 8.0 * t;
              return Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.only(top: top, left: 20, right: 20),
                  child: Text(
                    '打印',
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.bold,
                      color: theme.onSurface,
                      height: 1,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // ── Files section ───────────────────────────
        if (_store.files.isNotEmpty) ...[
          _SectionHeader(
            title: '文件',
            count: _store.files.length,
            trailing: TextButton(
              onPressed: () => _store.clearFiles(),
              child: Text(
                '清除',
                style: TextStyle(
                  color: theme.onSurface.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _FileCard(
                file: _store.files[i],
                uploadProgress:
                    _uploadProgress[_store.files[i].localPath ??
                        _store.files[i].storedName],
                onRemove: () => _store.removeFile(_store.files[i].storedName),
              ),
              childCount: _store.files.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ] else
          SliverToBoxAdapter(
            child: SizedBox(
              height: 450,
              child: Center(
                child: Text(
                  '未上传文件',
                  style: TextStyle(
                    color: theme.onSurface.withValues(alpha: 0.6),
                    fontSize: 36,
                  ),
                ),
              ),
            ),
          ),

        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 80,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              mainAxisSize: MainAxisSize.max,
              children: [
                FilledButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 20),
                  label: const Text('上传'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                ),
                FilledButton.icon(
                  onPressed: _store.files.isNotEmpty && !_submitting
                      ? _submit
                      : null,
                  icon: _submitting
                      ? SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: Text(
                    _store.files.isEmpty ? '提交' : '提交 ${_store.files.length}',

                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── Actions ─────────────────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'txt'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    for (final pf in result.files) {
      if (pf.path == null) continue;
      final localFile = File(pf.path!);
      // Add file to list immediately in uploading state.
      final placeholder = PrintFile(
        storedName: pf.name,
        displayName: pf.name,
        size: await localFile.length(),
        uploaded: false,
      );
      _store.addFile(placeholder);
      try {
        final uploaded = await _api.uploadFile(
          localFile,
          onProgress: (p) => setState(() => _uploadProgress[pf.name] = p),
        );
        // Replace placeholder with uploaded file.
        // The placeholder's storedName is the original filename (pf.name),
        // while the uploaded file has a UUID-based storedName from the server.
        // We must match by displayName (== pf.name) to find the placeholder.
        final idx = _store.files.indexWhere((f) => f.displayName == pf.name);
        if (idx >= 0) {
          _store.replaceFileAt(idx, uploaded);
        }
        _uploadProgress.remove(pf.name);
        setState(() {});
      } catch (e) {
        _uploadProgress.remove(pf.name);
        _store.removeFile(pf.name);
        _snackbar('上传失败：${pf.name} — $e', isError: true);
      }
    }
  }

  void _submit() async {
    if (_store.files.isEmpty) return;

    final selectedLocationId = await showLocationBottomSheet(
      context: context,
      locations: _store.locations,
    );
    if (selectedLocationId == null || !mounted) return;

    setState(() => _submitting = true);
    try {
      final count = await _store.submitAll(selectedLocationId);
      _snackbar('✓ 已提交 $count 个任务');
    } catch (e) {
      _snackbar('提交失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _snackbar(String msg, {bool isError = false}) {
    if (!mounted) return;
    final c = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? c.error.withValues(alpha: 0.9) : null,
      ),
    );
  }
}

// ─── Section Header ──────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Widget? trailing;
  const _SectionHeader({
    required this.title,
    required this.count,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: theme.onSurface.withValues(alpha: 0.6),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: theme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// ─── File Card ───────────────────────────────────────────────────
class _FileCard extends StatelessWidget {
  final PrintFile file;
  final double? uploadProgress;
  final VoidCallback onRemove;

  const _FileCard({
    required this.file,
    this.uploadProgress,
    required this.onRemove,
  });

  bool get _isUploading => uploadProgress != null && uploadProgress! < 1.0;

  void _showDetailPage(BuildContext context) {
    if (_isUploading) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FileDetailPage(file: file, onRemove: onRemove),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    return Card(
      elevation: _isUploading ? 1 : 3,
      child: InkWell(
        onTap: () => _showDetailPage(context),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              leading: SizedBox(
                width: 40,
                height: 48,
                child: Image.asset(
                  file.fileIcon,
                  fit: BoxFit.fill,
                  color: _isUploading
                      ? theme.onSurface.withValues(alpha: 0.3)
                      : null,
                  colorBlendMode: _isUploading ? BlendMode.modulate : null,
                ),
              ),
              title: Text(
                file.displayName,
                style: TextStyle(
                  color: _isUploading
                      ? theme.onSurface.withValues(alpha: 0.5)
                      : theme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              subtitle: _isUploading
                  ? Text(
                      '上传中 ${((uploadProgress ?? 0) * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.primary.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  : Row(
                      children: [
                        Icon(
                          Icons.data_usage_outlined,
                          size: 13,
                          color: theme.onSurface.withValues(alpha: 0.45),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          file.formattedSize,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '·',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.onSurface.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                        ValueListenableBuilder<PrintPriority>(
                          valueListenable: file.priority,
                          builder: (context, p, _) =>
                              PriorityBadge(priority: p),
                        ),
                      ],
                    ),
              trailing: _isUploading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        value: uploadProgress,
                        strokeWidth: 2,
                        color: theme.primary,
                      ),
                    )
                  : Icon(
                      Icons.chevron_right_rounded,
                      color: theme.onSurface.withValues(alpha: 0.3),
                    ),
            ),
            if (_isUploading)
              LinearProgressIndicator(
                value: uploadProgress,
                minHeight: 2,
                backgroundColor: theme.surfaceContainerHighest,
                color: theme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── File Detail Page ────────────────────────────────────────────
class _FileDetailPage extends StatelessWidget {
  final PrintFile file;
  final VoidCallback onRemove;

  const _FileDetailPage({required this.file, required this.onRemove});

  bool get _canPreview {
    final path = file.localPath;
    return path != null && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    final ext = file.storedName.split('.').last.toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件详情'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ext,
                  style: TextStyle(
                    fontSize: 12,
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ValueListenableBuilder<PrintPriority>(
            valueListenable: file.priority,
            builder: (context, currentPriority, _) => Column(
              children: [
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),

                        // File preview or fallback
                        if (_canPreview)
                          Container(
                            height: 280,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: theme.surfaceContainerHighest.withValues(
                                alpha: 0.3,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: theme.onSurface.withValues(alpha: 0.08),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: FilePreview.body(file),
                          )
                        else
                          Container(
                            height: 200,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: theme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: theme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Image.asset(
                                      file.fileIcon,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  file.displayName,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: theme.onSurface,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  file.formattedSize,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.onSurface.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                        const SizedBox(height: 24),

                        // File info
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    file.displayName,
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: theme.onSurface,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    file.formattedSize,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: theme.onSurface.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 36),

                        // Priority section
                        Text(
                          '优先级',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.onSurface.withValues(alpha: 0.6),
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: PrintPriority.values.map((p) {
                            final isSelected = p == currentPriority;
                            final color = p.color(theme);
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: GestureDetector(
                                  onTap: () {
                                    file.priority.value = p;
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? color.withValues(alpha: 0.15)
                                          : theme.surfaceContainerHighest
                                                .withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? color.withValues(alpha: 0.5)
                                            : theme.onSurface.withValues(
                                                alpha: 0.08,
                                              ),
                                        width: isSelected ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Text(
                                      p.label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? color
                                            : theme.onSurface.withValues(
                                                alpha: 0.5,
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom action bar
                Container(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: theme.onSurface.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            onRemove();
                          },
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('移除'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.error,
                            side: BorderSide(
                              color: theme.error.withValues(alpha: 0.3),
                            ),
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: const Text('完成'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Priority helpers are now methods on PrintPriority enum

// ─── Helpers ──────────────────────────────────────────────────────

// fileIcon is now provided by PrintFile.fileIcon getter
