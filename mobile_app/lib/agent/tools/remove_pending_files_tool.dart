import '../../services/pending_file_store.dart';
import 'agent_tool.dart';

/// Removes specific files from the pending area by a list of stored names.
class RemovePendingFilesTool extends AgentTool {
  const RemovePendingFilesTool();

  @override
  String get name => 'remove_pending_files';

  @override
  String get description =>
      '从待提交区删除指定的文件。'
      '提供一个存储名列表 (stored_names)，这些文件将从待提交区移除。'
      '注意：这只会从待提交区删除，不会影响已经提交的任务。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'stored_names': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': '要删除的文件存储名列表。',
      },
    },
    'required': ['stored_names'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final rawNames = arguments['stored_names'];
    if (rawNames is! List || rawNames.isEmpty) {
      return '错误：请提供 stored_names 参数（字符串列表）。';
    }

    final storedNames = rawNames.cast<String>().toList();
    final store = PendingFileStore.instance;

    final beforeCount = store.files.length;
    store.removeFiles(storedNames);
    final afterCount = store.files.length;
    final removedCount = beforeCount - afterCount;

    if (removedCount == 0) {
      return '未找到匹配的文件，待提交区未发生变化。'
          '请使用 list_pending_files 查看当前文件列表。';
    }

    return '已从待提交区删除 $removedCount 个文件，剩余 ${afterCount} 个文件。';
  }
}
