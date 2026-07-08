import '../agent_service.dart';
import '../models.dart';

/// Abstract base class for agent tools.
///
/// Subclasses define a [name], [description], and JSON-Schema [parameters],
/// then implement [execute] to handle tool calls.
///
/// Usage:
/// ```dart
/// class MyTool extends AgentTool {
///   @override
///   String get name => 'my_tool';
///   // ... implement execute
/// }
///
/// // Register in main.dart:
/// MyTool().register();
/// ```
abstract class AgentTool {
  const AgentTool();

  /// Tool name exposed to the LLM (snake_case by convention).
  String get name;

  /// Human-readable description of what this tool does.
  String get description;

  /// JSON-Schema definition of the tool's parameters.
  ///
  /// Example:
  /// ```dart
  /// {
  ///   'type': 'object',
  ///   'properties': {
  ///     'file_id': {
  ///       'type': 'string',
  ///       'description': 'The stored file name',
  ///     },
  ///   },
  ///   'required': ['file_id'],
  /// }
  /// ```
  Map<String, dynamic> get parameters;

  /// Execute the tool with the given [arguments] from the LLM.
  ///
  /// Must return a `String` that will be sent back as the tool result.
  Future<String> execute(Map<String, dynamic> arguments);

  /// Build the [ToolFunction] definition for this tool.
  ToolFunction get definition => ToolFunction(
    name: name,
    description: description,
    parameters: parameters,
  );

  /// Register this tool with the global [AgentService].
  void register() {
    AgentService.instance.registerTool(definition, execute);
  }

  // ─── Convenience helpers for subclasses ──────────────────────────

  /// Safely read a String argument.
  String? argString(Map<String, dynamic> args, String key) =>
      args[key] as String?;

  /// Safely read an int argument.
  int? argInt(Map<String, dynamic> args, String key) => args[key] as int?;

  /// Safely read a double argument.
  double? argDouble(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  /// Safely read a bool argument.
  bool? argBool(Map<String, dynamic> args, String key) => args[key] as bool?;
}
