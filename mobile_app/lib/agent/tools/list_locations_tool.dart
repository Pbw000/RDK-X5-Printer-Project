import '../../services/pending_file_store.dart';
import 'agent_tool.dart';

/// Lists all available delivery locations (print destinations).
class ListLocationsTool extends AgentTool {
  const ListLocationsTool();

  @override
  String get name => 'list_locations';

  @override
  String get description =>
      '列出所有可用的文件投递位置（打印目的地）。'
      '返回每个位置的 ID、名称和描述。提交文件时需要使用 location_id。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {},
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final store = PendingFileStore.instance;

    // Refresh locations if empty (may not have been loaded yet).
    if (store.locations.isEmpty) {
      await store.loadLocations();
    }

    final locations = store.locations;
    if (locations.isEmpty) {
      return '未找到任何投递位置，请检查服务器连接。';
    }

    final buf = StringBuffer();
    buf.writeln('【可用投递位置】(${locations.length} 个)');
    for (final loc in locations) {
      buf.writeln('  - ID: ${loc.id}  名称: ${loc.name}');
      if (loc.description.isNotEmpty) {
        buf.writeln('    描述: ${loc.description}');
      }
    }
    return buf.toString().trimRight();
  }
}
