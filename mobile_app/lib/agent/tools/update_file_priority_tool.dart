import '../../models/print_file.dart';
import '../../services/pending_file_store.dart';
import 'agent_tool.dart';

/// Updates the priority of a specific file in the pending area.
class UpdateFilePriorityTool extends AgentTool {
  const UpdateFilePriorityTool();

  @override
  String get name => 'update_file_priority';

  @override
  String get description =>
      '修改待提交区中指定文件的优先级。'
      '可以通过存储名 (stored_name) 或显示名 (display_name) 查找文件。'
      '优先级可选值：low、medium、high、critical。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'stored_name': {'type': 'string', 'description': '文件的存储名（精确匹配）。'},
      'display_name': {
        'type': 'string',
        'description': '文件的显示名（模糊匹配）。当不知道存储名时使用。',
      },
      'priority': {
        'type': 'string',
        'description': '新的优先级。可选值：low、medium、high、critical。',
        'enum': ['low', 'medium', 'high', 'critical'],
      },
    },
    'required': ['priority'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final storedName = argString(arguments, 'stored_name');
    final displayName = argString(arguments, 'display_name');
    final priorityStr = argString(arguments, 'priority');

    if (storedName == null && displayName == null) {
      return '错误：请提供 stored_name 或 display_name 参数来定位文件。';
    }
    if (priorityStr == null) {
      return '错误：请提供 priority 参数。';
    }

    final priority = PrintPriority.fromString(priorityStr);
    final store = PendingFileStore.instance;
    final files = store.files;

    if (files.isEmpty) {
      return '待提交区当前没有文件。';
    }

    // Resolve the target file.
    final target = files.cast<PrintFile?>().firstWhere(
      (f) =>
          (storedName != null && f!.storedName == storedName) ||
          (displayName != null && f!.displayName.contains(displayName)),
      orElse: () => null,
    );

    if (target == null) {
      return '未找到匹配的文件。请使用 list_pending_files 查看待提交区的所有文件。';
    }

    store.updatePriority(target.storedName, priority);
    return '已将文件 "${target.displayName}" 的优先级修改为 ${priority.label}。';
  }
}
