import '../../models/local_job.dart';
import '../../services/job_store.dart';
import 'agent_tool.dart';

/// Lists all current print files, grouped by state:
/// - 打印中 (printing)
/// - 已完成 / 待取件 (completed / waiting for pickup)
/// - 队列中 (queued / submitted)
class ListFilesTool extends AgentTool {
  const ListFilesTool();

  @override
  String get name => 'list_files';

  @override
  String get description =>
      '列出当前所有打印文件，按状态分类：打印中、已完成（待取件）、队列中。'
      '返回每个文件的名称、投递位置、优先级和大小。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {},
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final store = JobStore.instance;
    final printing = store.queuedJobs
        .where((j) => j.status == JobStatus.printing)
        .toList();
    final queued = store.queuedJobs
        .where((j) => j.status == JobStatus.submitted)
        .toList();
    final completed = store.waitingJobs;
    final confirmed = store.confirmedJobs;

    if (printing.isEmpty &&
        queued.isEmpty &&
        completed.isEmpty &&
        confirmed.isEmpty) {
      return '当前没有打印任务。';
    }

    final buf = StringBuffer();

    if (printing.isNotEmpty) {
      buf.writeln('【打印中】(${printing.length} 个文件)');
      for (final job in printing) {
        buf.writeln(_formatJob(job));
      }
      buf.writeln();
    }

    if (completed.isNotEmpty) {
      buf.writeln('【已完成 / 待取件】(${completed.length} 个文件)');
      for (final job in completed) {
        buf.writeln(_formatJob(job));
      }
      buf.writeln();
    }

    if (queued.isNotEmpty) {
      buf.writeln('【队列中】(${queued.length} 个文件)');
      for (final job in queued) {
        buf.writeln(_formatJob(job));
      }
      buf.writeln();
    }

    if (confirmed.isNotEmpty) {
      buf.writeln('【已确认 / 已取件】(${confirmed.length} 个文件)');
      for (final job in confirmed) {
        buf.writeln(_formatJob(job));
      }
    }

    return buf.toString().trimRight();
  }

  String _formatJob(LocalJob job) {
    return '  - ${job.displayName}  '
        '位置: ${job.locationName}  '
        '优先级: ${job.priority.label}  '
        '大小: ${job.formattedSize}';
  }
}
