import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'file_utils.dart';

enum PrintPriority {
  low,
  medium,
  high,
  critical;

  String toJson() => name[0].toUpperCase() + name.substring(1);

  static PrintPriority fromString(String s) => PrintPriority.values.firstWhere(
    (e) => e.name.toLowerCase() == s.toLowerCase(),
    orElse: () => PrintPriority.medium,
  );

  String get label => switch (this) {
    PrintPriority.low => '低',
    PrintPriority.medium => '中',
    PrintPriority.high => '高',
    PrintPriority.critical => '紧急',
  };

  Color color(ColorScheme theme) => switch (this) {
    PrintPriority.low => theme.secondary,
    PrintPriority.medium => theme.primary,
    PrintPriority.high => theme.tertiary,
    PrintPriority.critical => theme.error,
  };
}

class PrintFile {
  final String storedName;
  final String displayName;
  final int size;
  final bool uploaded;
  final String? localPath;
  final ValueNotifier<PrintPriority> priority;

  PrintFile({
    required this.storedName,
    required this.displayName,
    required this.size,
    this.uploaded = true,
    this.localPath,
    PrintPriority priorityValue = PrintPriority.medium,
  }) : priority = ValueNotifier(priorityValue);

  String get formattedSize => formatFileSize(size);
  String get fileIcon => fileIconForName(storedName);
}

/// Shared file-size formatter.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Reusable priority badge widget.
class PriorityBadge extends StatelessWidget {
  final PrintPriority priority;
  const PriorityBadge({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    final color = priority.color(Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Text(
        priority.label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
