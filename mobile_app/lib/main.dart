import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'agent/agent_service.dart';
import 'agent/tools/list_files_tool.dart';
import 'agent/tools/file_status_tool.dart';
import 'agent/tools/list_pending_files_tool.dart';
import 'agent/tools/list_locations_tool.dart';
import 'agent/tools/update_file_priority_tool.dart';
import 'agent/tools/remove_pending_files_tool.dart';
import 'agent/tools/submit_pending_files_tool.dart';
import 'services/database_service.dart';
import 'services/job_store.dart';
import 'services/pending_file_store.dart';
import 'services/printer_state_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();

  await DatabaseService.instance.init();
  final jobStore = JobStore.instance;
  await jobStore.init();
  await PendingFileStore.instance.init();

  // Register agent tools.
  ListFilesTool().register();
  FileStatusTool().register();
  ListPendingFilesTool().register();
  ListLocationsTool().register();
  UpdateFilePriorityTool().register();
  RemovePendingFilesTool().register();
  SubmitPendingFilesTool().register();

  runApp(
    LiquidGlassWidgets.wrap(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<JobStore>.value(value: jobStore),
          ChangeNotifierProvider<AgentService>.value(
            value: AgentService.instance,
          ),
          ChangeNotifierProvider<PrinterStateService>.value(
            value: PrinterStateService.instance,
          ),
          ChangeNotifierProvider<PendingFileStore>.value(
            value: PendingFileStore.instance,
          ),
        ],
        child: const PrinterApp(),
      ),
    ),
  );
}
