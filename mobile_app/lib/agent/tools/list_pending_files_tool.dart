import '../../services/pending_file_store.dart';
import 'agent_tool.dart';

/// Lists all files currently in the pending (uploaded but not submitted) area.
class ListPendingFilesTool extends AgentTool {
  const ListPendingFilesTool();

  @override
  String get name => 'list_pending_files';

  @override
  String get description =>
      '列出待提交区的所有文件（已上传但尚未提交的打印文件）。'
      '返回每个文件的存储名、显示名、优先级和大小。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {},
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final store = PendingFileStore.instance;
    final files = store.files;

    if (files.isEmpty) {
      return '待提交区当前没有文件。请先上传文件。';
    }

    final buf = StringBuffer();
    buf.writeln('【待提交区】(${files.length} 个文件)');
    for (final f in files) {
      buf.writeln(
        '  - ${f.displayName}  '
        '存储名: ${f.storedName}  '
        '优先级: ${f.priority.value.label}  '
        '大小: ${f.formattedSize}'
        '${f.uploaded ? "" : "  (上传中...)"}',
      );
    }
    return buf.toString().trimRight();
  }
}
