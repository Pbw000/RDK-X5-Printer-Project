// Agent module data models.
//
// Defines the types used for conversation context, tool calling,
// and streaming events in the OpenAI-compatible agent system.

enum MessageRole {
  system,
  user,
  assistant,
  tool;

  String toJson() => name;
}

/// A single message in the conversation history.
class ChatMessage {
  final String id;
  final MessageRole role;
  String content;
  final List<ToolCall>? toolCalls;
  final String? toolCallId;
  final String? name;
  final bool isError;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.toolCalls,
    this.toolCallId,
    this.name,
    this.isError = false,
  });

  // ─── Factory constructors ────────────────────────────────────

  factory ChatMessage.system(String content) =>
      ChatMessage(id: _genId(), role: MessageRole.system, content: content);

  factory ChatMessage.user(String content) =>
      ChatMessage(id: _genId(), role: MessageRole.user, content: content);

  factory ChatMessage.assistant([String content = '']) =>
      ChatMessage(id: _genId(), role: MessageRole.assistant, content: content);

  factory ChatMessage.withToolCalls(List<ToolCall> calls) => ChatMessage(
    id: _genId(),
    role: MessageRole.assistant,
    content: '',
    toolCalls: calls,
  );

  factory ChatMessage.toolResult({
    required String toolCallId,
    required String name,
    required String content,
  }) => ChatMessage(
    id: _genId(),
    role: MessageRole.tool,
    content: content,
    toolCallId: toolCallId,
    name: name,
  );

  factory ChatMessage.error(String message) => ChatMessage(
    id: _genId(),
    role: MessageRole.assistant,
    content: message,
    isError: true,
  );

  // ─── Serialization ──────────────────────────────────────────

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'role': role.toJson(), 'content': content};
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      json['tool_calls'] = toolCalls!.map((t) => t.toJson()).toList();
    }
    if (toolCallId != null) json['tool_call_id'] = toolCallId;
    if (name != null) json['name'] = name;
    return json;
  }

  static int _counter = 0;
  static String _genId() {
    _counter++;
    return 'msg_${DateTime.now().microsecondsSinceEpoch}_$_counter';
  }
}

/// A tool call made by the assistant.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': _encodeArgs(arguments)},
  };

  static String _encodeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '{}';
    final buf = StringBuffer('{');
    var first = true;
    args.forEach((key, value) {
      if (!first) buf.write(',');
      buf.write('"$key":');
      if (value is String) {
        buf.write('"$value"');
      } else {
        buf.write('$value');
      }
      first = false;
    });
    buf.write('}');
    return buf.toString();
  }
}

/// Function definition for OpenAI tool calling.
class ToolFunction {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const ToolFunction({
    required this.name,
    required this.description,
    required this.parameters,
  });

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// The result of executing a registered tool handler.
class ToolCallResult {
  final String toolCallId;
  final String name;
  final String content;

  const ToolCallResult({
    required this.toolCallId,
    required this.name,
    required this.content,
  });
}

// ─── Streaming Events ──────────────────────────────────────────

enum ChatStreamEventType {
  textDelta,
  toolCallStart,
  toolCallDelta,
  toolCallDone,
  done,
  error,
}

/// Event emitted during streaming from the agent.
class ChatStreamEvent {
  final ChatStreamEventType type;
  final String? content;
  final int? toolCallIndex;
  final ToolCall? toolCall;
  final String? error;

  const ChatStreamEvent({
    required this.type,
    this.content,
    this.toolCallIndex,
    this.toolCall,
    this.error,
  });

  factory ChatStreamEvent.textDelta(String delta) =>
      ChatStreamEvent(type: ChatStreamEventType.textDelta, content: delta);

  factory ChatStreamEvent.toolCallDone(ToolCall call) =>
      ChatStreamEvent(type: ChatStreamEventType.toolCallDone, toolCall: call);

  factory ChatStreamEvent.done() =>
      const ChatStreamEvent(type: ChatStreamEventType.done);

  factory ChatStreamEvent.error(String message) =>
      ChatStreamEvent(type: ChatStreamEventType.error, error: message);
}
