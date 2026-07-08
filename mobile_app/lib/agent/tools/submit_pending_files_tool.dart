import '../../services/pending_file_store.dart';
import 'agent_tool.dart';

/// Submits all pending files to a specified delivery location.
class SubmitPendingFilesTool extends AgentTool {
  const SubmitPendingFilesTool();

  @override
  String get name => 'submit_pending_files';

  @override
  String get description =>
      '提交待提交区的所有文件到指定的投递位置。'
      '必须提供 location_id（可通过 list_locations 工具获取）。'
      '提交后文件将从待提交区移除，并进入打印队列。';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'location_id': {
        'type': 'integer',
        'description': '投递位置的 ID（可通过 list_locations 获取）。',
      },
    },
    'required': ['location_id'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final locationId = argInt(arguments, 'location_id');
    if (locationId == null) {
      return '错误：请提供 location_id 参数。使用 list_locations 查看所有可用位置。';
    }

    final store = PendingFileStore.instance;

    if (store.files.isEmpty) {
      return '待提交区当前没有文件，无法提交。请先上传文件。';
    }

    if (store.isSubmitting) {
      return '当前正在提交文件，请稍后再试。';
    }

    // Validate that the location exists.
    final location = store.locations
        .where((l) => l.id == locationId)
        .firstOrNull;
    if (location == null) {
      return '错误：未找到 ID 为 $locationId 的投递位置。'
          '请使用 list_locations 查看所有可用位置。';
    }

    try {
      final count = await store.submitAll(locationId);
      return '✓ 已成功提交 $count 个文件到 "${location.name}"。';
    } catch (e) {
      return '提交失败：$e';
    }
  }
}
