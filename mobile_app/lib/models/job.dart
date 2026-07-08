import 'dart:convert';
import 'package:flutter/material.dart';

// ─── SSE Event Types ──────────────────────────────────────────────

sealed class SseEvent {
  const SseEvent();

  static SseEvent? fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) return null;
    final key = json.keys.first;
    final data = json[key] is Map<String, dynamic>
        ? json[key] as Map<String, dynamic>
        : <String, dynamic>{};

    return switch (key) {
      'PositionUpdate' => PositionUpdate(
        x: (data['x'] as num?)?.toDouble() ?? 0,
        y: (data['y'] as num?)?.toDouble() ?? 0,
        theta: (data['theta'] as num?)?.toDouble() ?? 0,
      ),
      'BatchStarted' => BatchStarted(
        locationId: data['location_id'] as int? ?? 0,
        locationName: data['location_name'] as String? ?? '',
        totalJobs: data['total_jobs'] as int? ?? 0,
      ),
      'PrintStarted' => PrintStarted(
        storeName: data['store_name'] as String? ?? '',
        locationId: data['location_id'] as int? ?? 0,
        jobIndex: data['job_index'] as int? ?? 0,
        totalJobs: data['total_jobs'] as int? ?? 0,
      ),
      'PrintComplete' => PrintComplete(
        storeName: data['store_name'] as String? ?? '',
        locationId: data['location_id'] as int? ?? 0,
      ),
      'PrintFailed' => PrintFailed(
        msg: data['msg'] as String? ?? '',
        locationId: data['location_id'] as int? ?? 0,
        storeName: data['store_name'] as String? ?? '',
      ),
      'BatchComplete' => BatchComplete(
        locationId: data['location_id'] as int? ?? 0,
        locationName: data['location_name'] as String? ?? '',
        succeeded: data['succeeded'] as int? ?? 0,
        failed: data['failed'] as int? ?? 0,
      ),
      'ConfirmTick' => ConfirmTick(
        remainingSecs: data['remaining_secs'] as int? ?? 0,
      ),
      'MovingTo' => (() {
        final pos = data['position'] is Map<String, dynamic>
            ? data['position'] as Map<String, dynamic>
            : <String, dynamic>{};
        return MovingTo(
          positionX: (pos['x_cord'] as num?)?.toDouble() ?? 0,
          positionY: (pos['y_cord'] as num?)?.toDouble() ?? 0,
          locationId: data['location_id'] as int? ?? 0,
          locationName: data['location_name'] as String? ?? '',
        );
      })(),
      'MoveComplete' => MoveComplete(
        locationId: data['location_id'] as int? ?? 0,
      ),
      'Idle' => const IdleEvent(),
      'SchedulerError' => SchedulerError(msg: data['msg'] as String? ?? ''),
      'NavError' => NavError(
        msg: data['msg'] as String? ?? '',
        locationId: data['location_id'] as int? ?? 0,
      ),
      _ => UnknownEvent(key, data),
    };
  }
}

class PositionUpdate extends SseEvent {
  final double x, y, theta;
  const PositionUpdate({required this.x, required this.y, required this.theta});

  @override
  String toString() =>
      'Position(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, θ=${theta.toStringAsFixed(2)})';
}

class MapUpdate extends SseEvent {
  final int width, height;
  final double resolution, originX, originY, originTheta;
  final String data;
  const MapUpdate({
    required this.width,
    required this.height,
    required this.resolution,
    required this.originX,
    required this.originY,
    required this.originTheta,
    required this.data,
  });
}

class BatchStarted extends SseEvent {
  final int locationId, totalJobs;
  final String locationName;
  const BatchStarted({
    required this.locationId,
    required this.locationName,
    required this.totalJobs,
  });

  @override
  String toString() => 'Batch → $locationName ($totalJobs jobs)';
}

class PrintStarted extends SseEvent {
  final String storeName;
  final int locationId, jobIndex, totalJobs;
  const PrintStarted({
    required this.storeName,
    required this.locationId,
    required this.jobIndex,
    required this.totalJobs,
  });

  @override
  String toString() =>
      'Print [$jobIndex/$totalJobs] $storeName @ location $locationId';
}

class PrintComplete extends SseEvent {
  final String storeName;
  final int locationId;
  const PrintComplete({required this.storeName, required this.locationId});

  @override
  String toString() => '✓ $storeName → location $locationId';
}

class PrintFailed extends SseEvent {
  final String msg, storeName;
  final int locationId;
  const PrintFailed({
    required this.msg,
    required this.locationId,
    required this.storeName,
  });

  @override
  String toString() => '✗ $storeName @ location $locationId: $msg';
}

class BatchComplete extends SseEvent {
  final int locationId, succeeded, failed;
  final String locationName;
  const BatchComplete({
    required this.locationId,
    required this.locationName,
    required this.succeeded,
    required this.failed,
  });

  @override
  String toString() =>
      'Batch $locationName done: $succeeded ok, $failed failed';
}

class ConfirmTick extends SseEvent {
  final int remainingSecs;
  const ConfirmTick({required this.remainingSecs});

  @override
  String toString() => 'Confirm: ${remainingSecs}s remaining';
}

class MovingTo extends SseEvent {
  final double positionX, positionY;
  final int locationId;
  final String locationName;
  const MovingTo({
    required this.positionX,
    required this.positionY,
    required this.locationId,
    required this.locationName,
  });

  @override
  String toString() =>
      'Moving to $locationName (${positionX.toStringAsFixed(2)}, ${positionY.toStringAsFixed(2)})';
}

class MoveComplete extends SseEvent {
  final int locationId;
  const MoveComplete({required this.locationId});

  @override
  String toString() => 'Arrived at location $locationId';
}

class IdleEvent extends SseEvent {
  const IdleEvent();

  @override
  String toString() => 'Idle';
}

class SchedulerError extends SseEvent {
  final String msg;
  const SchedulerError({required this.msg});

  @override
  String toString() => 'Scheduler error: $msg';
}

class NavError extends SseEvent {
  final String msg;
  final int locationId;
  const NavError({required this.msg, required this.locationId});

  @override
  String toString() => 'Nav error @ location $locationId: $msg';
}

class UnknownEvent extends SseEvent {
  final String type;
  final Map<String, dynamic> data;
  const UnknownEvent(this.type, this.data);
}

// ─── Printer Status ───────────────────────────────────────────────

enum PrinterStatus {
  idle,
  printing,
  moving,
  waitingConfirmation,
  unknown,
  error,
}

PrinterStatus parsePrinterStatus(String s) => PrinterStatus.values.firstWhere(
  (e) => e.name.toLowerCase() == s.toLowerCase(),
  orElse: () => PrinterStatus.unknown,
);

/// Parse the full response from GET /api/printer/status
/// Response format: { "status": <PrinterStatus> }
/// where status is either a string like "Idle" or an object like {"Printing":{"total":5,"processed":2}}
PrinterStatus parsePrinterStatusResponse(Map<String, dynamic> body) {
  final status = body['status'];
  if (status is String) {
    return parsePrinterStatus(status);
  }
  if (status is Map<String, dynamic>) {
    final key = status.keys.first;
    if (key.toLowerCase() == 'printing') return PrinterStatus.printing;
    return PrinterStatus.unknown;
  }
  return PrinterStatus.unknown;
}

/// Rich printer status with printing progress info.
class PrinterStatusInfo {
  final PrinterStatus status;
  final int? printingTotal;
  final int? printingProcessed;

  const PrinterStatusInfo({
    required this.status,
    this.printingTotal,
    this.printingProcessed,
  });

  bool get isPrinting => status == PrinterStatus.printing;
  bool get isWaitingConfirmation => status == PrinterStatus.waitingConfirmation;
  String get progressText => isPrinting && printingTotal != null
      ? '$printingProcessed/$printingTotal'
      : '';
}

/// Parse the full response into a rich [PrinterStatusInfo].
PrinterStatusInfo parsePrinterStatusInfoResponse(Map<String, dynamic> body) {
  final status = body['status'];
  if (status is String) {
    return PrinterStatusInfo(status: parsePrinterStatus(status));
  }
  if (status is Map<String, dynamic>) {
    final key = status.keys.first;
    if (key.toLowerCase() == 'printing') {
      final inner = status[key] as Map<String, dynamic>?;
      return PrinterStatusInfo(
        status: PrinterStatus.printing,
        printingTotal: inner?['total'] as int?,
        printingProcessed: inner?['processed'] as int?,
      );
    }
    return const PrinterStatusInfo(status: PrinterStatus.unknown);
  }
  return const PrinterStatusInfo(status: PrinterStatus.unknown);
}

// ─── SSE line parser ──────────────────────────────────────────────

SseEvent? parseSseLine(String line) {
  final jsonStr = line.startsWith('data:') ? line.substring(5).trim() : line;
  if (jsonStr.isEmpty) return null;
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is String) {
      if (decoded == 'Idle') return const IdleEvent();
      return null;
    }
    if (decoded is Map<String, dynamic>) return SseEvent.fromJson(decoded);
  } catch (_) {}
  return null;
}

// ─── File State ───────────────────────────────────────────────────

enum FileState {
  pending,
  printing,
  transferring,
  waitingForPickUp,
  removed;

  String toJson() => name;

  static FileState fromString(String s) => FileState.values.firstWhere(
    (e) => e.name.toLowerCase() == s.toLowerCase(),
    orElse: () => FileState.removed,
  );

  String get label => switch (this) {
    FileState.pending => '等待中',
    FileState.printing => '打印中',
    FileState.transferring => '传输中',
    FileState.waitingForPickUp => '待取件',
    FileState.removed => '已移除',
  };

  IconData get icon => switch (this) {
    FileState.pending => Icons.schedule_rounded,
    FileState.printing => Icons.print_rounded,
    FileState.transferring => Icons.swap_horiz_rounded,
    FileState.waitingForPickUp => Icons.inventory_2_outlined,
    FileState.removed => Icons.delete_outline_rounded,
  };

  Color color(ColorScheme theme) => switch (this) {
    FileState.pending => theme.secondary,
    FileState.printing => theme.primary,
    FileState.transferring => theme.tertiary,
    FileState.waitingForPickUp => theme.tertiary,
    FileState.removed => theme.error,
  };
}

// ─── Job Response ─────────────────────────────────────────────────

class JobResponse {
  final String storedName;
  final int estTimeSec;
  const JobResponse({required this.storedName, required this.estTimeSec});
  factory JobResponse.fromJson(Map<String, dynamic> json) => JobResponse(
    storedName: json['stored_name'] as String? ?? '',
    estTimeSec: json['est_time_sec'] as int? ?? 0,
  );
}

// ─── Navigation Status ────────────────────────────────────────────

class RouteSegment {
  final int locationId;
  final double estimatedTimeSecs;
  const RouteSegment({
    required this.locationId,
    required this.estimatedTimeSecs,
  });
  factory RouteSegment.fromJson(Map<String, dynamic> json) => RouteSegment(
    locationId: json['location_id'] as int? ?? 0,
    estimatedTimeSecs: (json['estimated_time_secs'] as num?)?.toDouble() ?? 0,
  );
}

class NavigationStatus {
  final List<RouteSegment> route;
  const NavigationStatus(this.route);
  factory NavigationStatus.fromJson(Map<String, dynamic> json) {
    final list = json['route'] as List<dynamic>? ?? [];
    return NavigationStatus(
      list
          .map((e) => RouteSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
  double get totalTimeSecs =>
      route.fold(0, (sum, s) => sum + s.estimatedTimeSecs);
}
