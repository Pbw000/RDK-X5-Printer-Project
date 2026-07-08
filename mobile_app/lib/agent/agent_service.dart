import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'models.dart';

/// Signature for tool handler functions.
typedef ToolHandler = Future<String> Function(Map<String, dynamic> arguments);

class _ToolEntry {
  final ToolFunction definition;
  final ToolHandler handler;
  const _ToolEntry(this.definition, this.handler);
}

/// Accumulates streaming data for a single tool call.
class _PendingToolCall {
  String? id;
  String? name;
  final StringBuffer argsBuffer = StringBuffer();
}

/// Agent service with OpenAI-compatible streaming, tool calling,
/// and conversation context management.
///
/// Follows the singleton + ChangeNotifier pattern used elsewhere in the app.
class AgentService extends ChangeNotifier {
  static final AgentService _instance = AgentService._();
  static AgentService get instance => _instance;
  AgentService._();

  // ─── Configuration ──────────────────────────────────────────

  /// OpenAI-compatible API base URL.
  String baseUrl = 'https://your-llm-api.example.com/v1';

  /// Model identifier.
  String model = 'your-model-name';

  /// API key for authentication.
  String apiKey = 'your-api-key';

  /// System prompt sent at the start of each conversation.
  String systemPrompt =
      '你是一个实用的打印助手。'
      '帮助用户管理打印任务、查看打印机状态和提交文件。';

  // ─── Tool registry ──────────────────────────────────────────

  final Map<String, _ToolEntry> _tools = {};

  void registerTool(ToolFunction definition, ToolHandler handler) {
    _tools[definition.name] = _ToolEntry(definition, handler);
  }

  void unregisterTool(String name) => _tools.remove(name);

  List<ToolFunction> get toolDefinitions =>
      _tools.values.map((e) => e.definition).toList();

  // ─── Conversation context ──────────────────────────────────

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;

  http.Client? _httpClient;
  bool _shouldStop = false;

  // ─── Streaming event bus ────────────────────────────────────

  final StreamController<ChatStreamEvent> _streamController =
      StreamController<ChatStreamEvent>.broadcast();

  /// Subscribe to this stream for fine-grained UI updates during streaming.
  Stream<ChatStreamEvent> get stream => _streamController.stream;

  // ─── Public API ─────────────────────────────────────────────

  /// Clear all conversation history.
  void clearConversation() {
    _messages.clear();
    notifyListeners();
  }

  /// Send a user message and stream the assistant's response.
  ///
  /// Handles the full tool-calling loop: if the model requests tool calls,
  /// they are executed and results are sent back until a final text
  /// response is produced.
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty || _isStreaming) return;

    _shouldStop = false;
    _messages.add(ChatMessage.user(content));
    notifyListeners();

    _isStreaming = true;
    notifyListeners();

    try {
      var keepGoing = true;
      while (keepGoing && !_shouldStop) {
        final hasToolCalls = await _streamOneTurn();
        keepGoing = hasToolCalls;
      }
    } catch (e) {
      _streamController.add(ChatStreamEvent.error(e.toString()));
      _messages.add(ChatMessage.error('Error: $e'));
      notifyListeners();
    } finally {
      _isStreaming = false;
      _shouldStop = false;
      notifyListeners();
    }
  }

  /// Cancel the current streaming request.
  void stopStreaming() {
    _shouldStop = true;
    _httpClient?.close();
    _httpClient = null;
    _isStreaming = false;
    notifyListeners();
  }

  /// Stub for voice output — triggered on long-press of a message.
  Future<void> speakMessage(String text) async {
    // TODO: Integrate TTS (e.g. flutter_tts).
    debugPrint('[AgentService] speakMessage: ${text.length} chars');
  }

  @override
  void dispose() {
    _streamController.close();
    _httpClient?.close();
    super.dispose();
  }

  // ─── Streaming implementation ───────────────────────────────

  /// Streams one turn to the API and processes the response.
  /// Returns `true` if the model requested tool calls (loop should continue).
  Future<bool> _streamOneTurn() async {
    _httpClient?.close();
    _httpClient = http.Client();

    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/chat/completions'),
    );
    request.headers['Content-Type'] = 'application/json';
    if (apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $apiKey';
    }

    final messagesJson = <Map<String, dynamic>>[
      ChatMessage.system(systemPrompt).toJson(),
      ..._messages.map((m) => m.toJson()),
    ];

    final bodyJson = <String, dynamic>{
      'model': model,
      'messages': messagesJson,
      'stream': true,
    };
    if (_tools.isNotEmpty) {
      bodyJson['tools'] = toolDefinitions.map((t) => t.toJson()).toList();
    }

    request.body = jsonEncode(bodyJson);

    final response = await _httpClient!.send(request);

    if (response.statusCode != 200) {
      final body = await response.stream.transform(utf8.decoder).join();
      throw Exception('API error ${response.statusCode}: $body');
    }

    // Create assistant message placeholder.
    final assistant = ChatMessage.assistant('');
    _messages.add(assistant);
    notifyListeners();

    // Pending tool calls accumulated during streaming.
    final pendingToolCalls = <int, _PendingToolCall>{};
    var accumulatedContent = '';
    var buffer = '';

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      if (_shouldStop) break;

      buffer += chunk;
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx == -1) break;
        var line = buffer.substring(0, idx).trim();
        buffer = buffer.substring(idx + 1);

        if (line.startsWith('data: ')) {
          line = line.substring(6);
        }
        if (line.isEmpty || line == '[DONE]') continue;

        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;

          final choice = choices[0] as Map<String, dynamic>;
          final delta = choice['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;

          // ─── Text content delta ─────────────────────
          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty) {
            accumulatedContent += content;
            assistant.content = accumulatedContent;
            _streamController.add(ChatStreamEvent.textDelta(content));
            notifyListeners();
          }

          // ─── Tool call deltas ───────────────────────
          final toolCalls = delta['tool_calls'] as List?;
          if (toolCalls != null) {
            for (final tc in toolCalls) {
              final tcMap = tc as Map<String, dynamic>;
              final index = tcMap['index'] as int? ?? 0;

              if (!pendingToolCalls.containsKey(index)) {
                pendingToolCalls[index] = _PendingToolCall();
              }
              final pending = pendingToolCalls[index]!;

              // Call ID.
              final id = tcMap['id'] as String?;
              if (id != null) pending.id = id;

              // Function name and arguments.
              final fn = tcMap['function'] as Map<String, dynamic>?;
              if (fn != null) {
                final name = fn['name'] as String?;
                if (name != null) pending.name = name;
                final args = fn['arguments'] as String?;
                if (args != null) pending.argsBuffer.write(args);
              }
            }
            notifyListeners();
          }
        } catch (_) {
          // Malformed JSON line — skip silently.
        }
      }
    }

    // ─── Process accumulated tool calls ─────────────────────
    if (pendingToolCalls.isNotEmpty) {
      final calls = <ToolCall>[];
      for (final entry in pendingToolCalls.entries) {
        final pending = entry.value;
        Map<String, dynamic> args = {};
        try {
          final raw = pending.argsBuffer.toString();
          if (raw.isNotEmpty) {
            args = jsonDecode(raw) as Map<String, dynamic>;
          }
        } catch (_) {}

        final call = ToolCall(
          id: pending.id ?? 'call_unknown',
          name: pending.name ?? 'unknown',
          arguments: args,
        );
        calls.add(call);
        _streamController.add(ChatStreamEvent.toolCallDone(call));
      }

      // Replace assistant placeholder with tool-call message.
      _messages.removeLast();
      _messages.add(ChatMessage.withToolCalls(calls));
      notifyListeners();

      // Execute tool handlers and collect results.
      for (final call in calls) {
        final entry = _tools[call.name];
        if (entry != null) {
          try {
            final result = await entry.handler(call.arguments);
            _messages.add(
              ChatMessage.toolResult(
                toolCallId: call.id,
                name: call.name,
                content: result,
              ),
            );
          } catch (e) {
            _messages.add(
              ChatMessage.toolResult(
                toolCallId: call.id,
                name: call.name,
                content: '执行工具出错：$e',
              ),
            );
          }
        } else {
          _messages.add(
            ChatMessage.toolResult(
              toolCallId: call.id,
              name: call.name,
              content: '工具「${call.name}」未注册。',
            ),
          );
        }
        notifyListeners();
      }
      return true; // Continue the loop for the next turn.
    }

    return false; // No tool calls — done.
  }
}
