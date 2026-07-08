import 'package:flutter/material.dart';
import 'print_file.dart';
import 'file_utils.dart';

/// Print job status lifecycle: submitted → printing → completed → confirmed | failed
enum JobStatus {
  submitted,
  printing,
  completed,
  confirmed,
  failed;

  String toJson() => name;

  static JobStatus fromString(String s) => JobStatus.values.firstWhere(
    (e) => e.name == s,
    orElse: () => JobStatus.submitted,
  );

  bool get isActive => this == submitted || this == printing;
  bool get isDone => this == completed || this == confirmed;
  bool get isFailed => this == failed;
  bool get isCompleted => this == completed;

  String get label => switch (this) {
    JobStatus.submitted => '队列中',
    JobStatus.printing => '打印中',
    JobStatus.completed => '已完成',
    JobStatus.confirmed => '已确认',
    JobStatus.failed => '失败',
  };

  IconData get icon => switch (this) {
    JobStatus.submitted => Icons.schedule_rounded,
    JobStatus.printing => Icons.print_rounded,
    JobStatus.completed => Icons.check_circle_outline_rounded,
    JobStatus.confirmed => Icons.verified_rounded,
    JobStatus.failed => Icons.error_outline_rounded,
  };

  Color color(ColorScheme theme) => switch (this) {
    JobStatus.submitted => theme.secondary,
    JobStatus.printing => theme.primary,
    JobStatus.completed => theme.primary,
    JobStatus.confirmed => theme.tertiary,
    JobStatus.failed => theme.error,
  };
}

/// Local job record — persisted in SQLite, represents one user-submitted file.
class LocalJob {
  final int? id;
  final String storedName;
  final String displayName;
  final int locationId;
  final String locationName;
  final PrintPriority priority;
  final int fileSize;
  final JobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LocalJob({
    this.id,
    required this.storedName,
    required this.displayName,
    required this.locationId,
    required this.locationName,
    required this.priority,
    required this.fileSize,
    this.status = JobStatus.submitted,
    required this.createdAt,
    required this.updatedAt,
  });

  LocalJob copyWith({int? id, JobStatus? status, DateTime? updatedAt}) =>
      LocalJob(
        id: id ?? this.id,
        storedName: storedName,
        displayName: displayName,
        locationId: locationId,
        locationName: locationName,
        priority: priority,
        fileSize: fileSize,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'stored_name': storedName,
    'display_name': displayName,
    'location_id': locationId,
    'location_name': locationName,
    'priority': priority.name,
    'file_size': fileSize,
    'status': status.toJson(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory LocalJob.fromMap(Map<String, dynamic> map) => LocalJob(
    id: map['id'] as int?,
    storedName: map['stored_name'] as String,
    displayName: map['display_name'] as String,
    locationId: map['location_id'] as int,
    locationName: map['location_name'] as String,
    priority: PrintPriority.fromString(map['priority'] as String),
    fileSize: map['file_size'] as int,
    status: JobStatus.fromString(map['status'] as String),
    createdAt: DateTime.parse(map['created_at'] as String),
    updatedAt: DateTime.parse(map['updated_at'] as String),
  );

  String get formattedSize => formatFileSize(fileSize);

  bool get isActive => status.isActive;
  bool get isDone => status.isDone;
  bool get isFailed => status.isFailed;

  String get fileIcon => fileIconForName(displayName);
}
