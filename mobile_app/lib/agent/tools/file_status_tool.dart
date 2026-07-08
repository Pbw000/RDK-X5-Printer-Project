import '../../services/api_service.dart';
import '../../services/job_store.dart';
import '../../models/local_job.dart';
import 'agent_tool.dart';

/// Queries the status of a specific print file by its stored name.
///
/// Returns:
/// - File state (pending / printing / transferring / waitingForPickUp / removed)
/// - Delivery location name
/// - Estimated arrival time (from navigation status, if available)
class FileStatusTool extends AgentTool {
  const FileStatusTool();

  @override
  String get name => 'file_status';

  @override
  String get description =>
      '查询指定打印文件的当前状态和预计到达时间。'
      '可以通过文件存储名 (stored_name) 或显示名 (display_name) 查找。'
      '返回文件状态、投递位置和导航预计到达时间。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'stored_name': {
        'type': 'string',
        'description': '文件的存储名（精确匹配）。如果不知道存储名，可以用 display_name 模糊查找。',
      },
      'display_name': {
        'type': 'string',
        'description': '文件的显示名（模糊匹配）。当不知道存储名时使用。',
      },
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final storedName = argString(arguments, 'stored_name');
    final displayName = argString(arguments, 'display_name');

    if (storedName == null && displayName == null) {
      return '错误：请提供 stored_name 或 display_name 参数。';
    }

    final store = JobStore.instance;

    // Resolve the stored name: exact match first, then fuzzy on display name.
    String resolvedName;
    if (storedName != null) {
      resolvedName = storedName;
    } else {
      // Fuzzy search by display name across all known jobs.
      final allJobs = [
        ...store.queuedJobs,
        ...store.waitingJobs,
        ...store.confirmedJobs,
      ];
      final match = allJobs.cast<LocalJob?>().firstWhere(
        (j) => j!.displayName.contains(displayName!),
        orElse: () => null,
      );
      if (match == null) {
        return '未找到显示名为 "$displayName" 的文件。'
            '请检查文件名是否正确，或使用 list_files 工具查看所有文件。';
      }
      resolvedName = match.storedName;
    }

    // Look up local job info.
    final allJobs = [
      ...store.queuedJobs,
      ...store.waitingJobs,
      ...store.confirmedJobs,
    ];
    final localJob = allJobs.cast<LocalJob?>().firstWhere(
      (j) => j!.storedName == resolvedName,
      orElse: () => null,
    );

    // Query backend for real-time file state.
    final fileState = await ApiService.instance.getFileStatus(resolvedName);

    final buf = StringBuffer();
    buf.writeln('文件: ${localJob?.displayName ?? resolvedName}');
    buf.writeln('存储名: $resolvedName');

    if (fileState != null) {
      buf.writeln('后端状态: ${fileState.label}');
    } else {
      buf.writeln('后端状态: 无法连接服务器');
    }

    if (localJob != null) {
      buf.writeln('本地状态: ${localJob.status.label}');
      buf.writeln(
        '投递位置: ${localJob.locationName} (ID: ${localJob.locationId})',
      );
      buf.writeln('优先级: ${localJob.priority.label}');
      buf.writeln('文件大小: ${localJob.formattedSize}');
      buf.writeln('提交时间: ${_formatTime(localJob.createdAt)}');
    }

    // Try to get navigation ETA to the delivery location.
    if (localJob != null) {
      final eta = await _getEtaToLocation(localJob.locationId);
      if (eta != null) {
        buf.writeln('预计到达时间: ${_formatDuration(eta)}');
      }
    }

    return buf.toString().trimRight();
  }

  /// Query navigation status and find the ETA to a specific location.
  Future<double?> _getEtaToLocation(int locationId) async {
    try {
      final nav = await ApiService.instance.getNavigationStatus();
      for (final segment in nav.route) {
        if (segment.locationId == locationId) {
          return segment.estimatedTimeSecs;
        }
      }
    } catch (_) {
      // Navigation unavailable — not critical.
    }
    return null;
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  String _formatDuration(double seconds) {
    if (seconds < 60) return '${seconds.round()} 秒后';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes 分钟后';
    final hours = minutes ~/ 60;
    final remainingMin = minutes % 60;
    return '$hours 小时 $remainingMin 分钟后';
  }
}
