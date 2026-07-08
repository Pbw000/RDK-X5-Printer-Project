import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'dart:io' show Platform;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../agent/agent_service.dart';
import '../agent/models.dart';
import '../audio/audio_service.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send([String? overrideText]) async {
    final text = (overrideText ?? _inputController.text).trim();
    if (text.isEmpty) return;
    await context.read<AgentService>().sendMessage(text);
  }

  void _stop() => context.read<AgentService>().stopStreaming();

  Future<void> _speak(String text) async {
    await context.read<AgentService>().speakMessage(text);
  }

  /// Groups messages into display turns.
  /// An assistant message with tool calls + its tool result messages
  /// are aggregated into a single [_MessageGroup] rendered by [_ToolCallsCard].
  List<_MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <_MessageGroup>[];
    var i = 0;
    while (i < messages.length) {
      final msg = messages[i];

      // Assistant message with tool calls → collect following tool results
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        final results = <String, ChatMessage>{};
        var j = i + 1;
        while (j < messages.length && messages[j].role == MessageRole.tool) {
          results[messages[j].toolCallId!] = messages[j];
          j++;
        }
        groups.add(
          _MessageGroup(
            id: msg.id,
            assistantMessage: msg,
            toolCalls: msg.toolCalls!,
            results: results,
          ),
        );
        i = j;
        continue;
      }

      // Tool result that wasn't grouped (edge case) → skip
      if (msg.role == MessageRole.tool) {
        i++;
        continue;
      }

      // Regular message → standalone group
      groups.add(
        _MessageGroup(id: msg.id, assistantMessage: msg, toolCalls: const []),
      );
      i++;
    }
    return groups;
  }

  Widget _buildMessageList(AgentService service) {
    final groups = _groupMessages(service.messages);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final isLast = index == groups.length - 1;
        final isStreaming = service.isStreaming && isLast;

        // Tool group → animated tool calls card
        if (group.toolCalls.isNotEmpty) {
          return _ToolCallsCard(
            key: ValueKey(group.id),
            group: group,
            isStreaming: isStreaming,
          );
        }

        // Regular message → bubble with fade entrance
        return _MessageItem(
          key: ValueKey(group.id),
          message: group.assistantMessage,
          isStreaming: isStreaming,
          onLongPress: group.assistantMessage.role == MessageRole.assistant
              ? () => _speak(group.assistantMessage.content)
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, service, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });

        final theme = Theme.of(context).colorScheme;

        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('助手'),
            backgroundColor: theme.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 20,
          ),
          body: Column(
            children: [
              Expanded(
                child: service.messages.isEmpty
                    ? const _EmptyState()
                    : _buildMessageList(service),
              ),
              _InputBar(
                controller: _inputController,
                focusNode: _focusNode,
                isStreaming: service.isStreaming,
                onSend: _send,
                onStop: _stop,
                audioService: AudioService.instance,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Empty State ────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Icon(
                CupertinoIcons.chat_bubble_2,
                size: 64,
                color: onSurface.withValues(alpha: 0.4),
              ),
              Text(
                '打印助手',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                '有什么关于打印的问题？',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Message Item ───────────────────────────────────────────────

class _MessageItem extends StatefulWidget {
  final ChatMessage message;
  final bool isStreaming;
  final VoidCallback? onLongPress;

  const _MessageItem({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.onLongPress,
  });

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _MessageBubble(
          message: widget.message,
          isStreaming: widget.isStreaming,
          onLongPress: widget.onLongPress,
        ),
      ),
    );
  }
}

// ─── Message Bubble (iOS style) ─────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isStreaming;
  final VoidCallback? onLongPress;

  const _MessageBubble({
    required this.message,
    this.isStreaming = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isError = message.isError;

    final cs = Theme.of(context).colorScheme;
    final bubbleColor = isUser
        ? cs.primary
        : isError
        ? cs.error.withValues(alpha: 0.15)
        : cs.surfaceContainerHighest;

    final textColor = isUser
        ? cs.onPrimary
        : isError
        ? cs.error
        : cs.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: onLongPress != null
            ? (_) {
                HapticFeedback.mediumImpact();
                onLongPress!();
              }
            : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
            ),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                if (isStreaming && message.content.isEmpty)
                  _TypingDots(color: textColor)
                else if (isUser)
                  Text(
                    message.content,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.35,
                      color: textColor,
                    ),
                  )
                else
                  MarkdownBody(
                    data: message.content,
                    selectable: false,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        fontSize: 16,
                        height: 1.35,
                        color: textColor,
                      ),
                      h1: TextStyle(
                        fontSize: 24,
                        height: 1.3,
                        color: textColor,
                        fontWeight: FontWeight.bold,
                      ),
                      h2: TextStyle(
                        fontSize: 20,
                        height: 1.3,
                        color: textColor,
                        fontWeight: FontWeight.bold,
                      ),
                      h3: TextStyle(
                        fontSize: 18,
                        height: 1.3,
                        color: textColor,
                        fontWeight: FontWeight.bold,
                      ),
                      code: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: textColor,
                        fontFamily: 'monospace',
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: cs.primary.withValues(alpha: 0.5),
                            width: 3,
                          ),
                        ),
                      ),
                      listBullet: TextStyle(fontSize: 16, color: textColor),
                    ),
                  ),
                if (isStreaming && message.content.isNotEmpty)
                  _StreamingCursor(color: textColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Message Group (tool turn aggregation) ──────────────────────

class _MessageGroup {
  final String id;
  final ChatMessage assistantMessage;
  final List<ToolCall> toolCalls;
  final Map<String, ChatMessage> results;

  _MessageGroup({
    required this.id,
    required this.assistantMessage,
    required this.toolCalls,
    Map<String, ChatMessage>? results,
  }) : results = results ?? {};
}

// ─── Tool Calls Card (in-place updating, animated) ──────────────

class _ToolCallsCard extends StatefulWidget {
  final _MessageGroup group;
  final bool isStreaming;

  const _ToolCallsCard({
    super.key,
    required this.group,
    this.isStreaming = false,
  });

  @override
  State<_ToolCallsCard> createState() => _ToolCallsCardState();
}

class _ToolCallsCardState extends State<_ToolCallsCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutCubic,
          ),
        );
    _fadeAnimation = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final group = widget.group;
    final resultCount = group.results.length;
    final totalCount = group.toolCalls.length;

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: child,
                ),
              );
            },
            child: Container(
              key: ValueKey('${group.id}_$resultCount'),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Header bar ──
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.06),
                    ),
                    child: Row(
                      spacing: 8,
                      children: [
                        Icon(
                          CupertinoIcons.wrench_fill,
                          size: 14,
                          color: cs.primary,
                        ),
                        Expanded(
                          child: Text(
                            '正在调用 ${totalCount} 个工具',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                        ),
                        if (resultCount < totalCount)
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: cs.primary,
                            ),
                          )
                        else
                          Icon(
                            CupertinoIcons.checkmark_circle_fill,
                            size: 14,
                            color: cs.primary,
                          ),
                      ],
                    ),
                  ),
                  // ── Tool rows ──
                  ...group.toolCalls.map((tc) => _buildToolRow(context, tc)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolRow(BuildContext context, ToolCall tc) {
    final cs = Theme.of(context).colorScheme;
    final result = widget.group.results[tc.id];
    final isPending = result == null;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-0.05, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: Container(
        key: ValueKey('${tc.id}_${isPending ? "pending" : "done"}'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: cs.outline.withValues(alpha: 0.08)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            // Tool name + status
            Row(
              spacing: 8,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: isPending
                      ? SizedBox(
                          key: ValueKey('${tc.id}_spinner'),
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: cs.primary.withValues(alpha: 0.7),
                          ),
                        )
                      : Icon(
                          key: ValueKey('${tc.id}_check'),
                          CupertinoIcons.checkmark_circle_fill,
                          size: 13,
                          color: const Color(0xFF34C759),
                        ),
                ),
                Expanded(
                  child: Text(
                    tc.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            // Result content (animated in when available)
            if (result != null)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2),
                child: Text(
                  result.content,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Streaming Cursor ───────────────────────────────────────────

class _StreamingCursor extends StatelessWidget {
  final Color color;
  const _StreamingCursor({required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: 0.4,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

// ─── Typing Dots (inline, used inside message bubble) ───────────

class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: const Size(30, 7),
        painter: _TypingPainter(
          progress: _controller.value,
          color: widget.color,
        ),
      ),
    );
  }
}

class _TypingPainter extends CustomPainter {
  final double progress;
  final Color color;

  _TypingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const dotSize = 7.0;
    const spacing = 11.5;

    for (var i = 0; i < 3; i++) {
      final t = (progress - i * 0.15).clamp(0.0, 1.0);
      final y = -5.0 * math.sin(t * math.pi);
      canvas.drawCircle(
        Offset(i * spacing + dotSize / 2, size.height / 2 + y),
        dotSize / 2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TypingPainter old) => old.progress != progress;
}

// ─── Input Bar ──────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isStreaming;
  final Future<void> Function([String?]) onSend;
  final VoidCallback onStop;
  final AudioService audioService;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.isStreaming,
    required this.onSend,
    required this.onStop,
    required this.audioService,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _recording = false;
  StreamSubscription<String>? _asrSub;

  @override
  void dispose() {
    _asrSub?.cancel();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    final asr = widget.audioService;
    if (_recording) {
      final text = widget.controller.text.trim();
      await asr.stop();
      _asrSub?.cancel();
      _asrSub = null;
      widget.controller.clear();
      setState(() => _recording = false);
      if (text.isNotEmpty) await widget.onSend(text);
    } else {
      try {
        // 请求麦克风权限（Windows 不需要）
        if (!Platform.isWindows) {
          final status = await Permission.microphone.request();
          if (!status.isGranted) {
            if (mounted) {
              final msg = status.isPermanentlyDenied
                  ? '麦克风权限被永久拒绝，请在系统设置中手动开启'
                  : '麦克风权限被拒绝，无法使用语音输入';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(msg),
                  action: status.isPermanentlyDenied
                      ? SnackBarAction(
                          label: '去设置',
                          onPressed: () => openAppSettings(),
                        )
                      : null,
                ),
              );
            }
            return;
          }
        }

        widget.controller.clear();
        await asr.start();
        _asrSub = asr.textStream.listen((text) {
          if (mounted) widget.controller.text = text;
        });
        setState(() => _recording = true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('语音输入失败：$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 40),
      child: GlassTextField(
        useOwnLayer: true,
        shape: const LiquidRoundedSuperellipse(borderRadius: 37),
        controller: widget.controller,
        focusNode: widget.focusNode,
        placeholder: _recording ? '正在聆听…' : '输入消息',
        placeholderStyle: TextStyle(color: onSurface.withValues(alpha: 0.4)),
        maxLines: 4,
        minLines: 1,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => widget.onSend(),
        prefixIcon: IconButton(
          onPressed: _toggleRecording,
          iconSize: 36,
          icon: Icon(
            _recording ? CupertinoIcons.mic_fill : CupertinoIcons.mic,
            size: 36,
            color: _recording
                ? Theme.of(context).colorScheme.error
                : onSurface.withValues(alpha: 0.38),
          ),
        ),
        suffixIcon: Icon(
          widget.isStreaming
              ? CupertinoIcons.stop_fill
              : CupertinoIcons.arrow_up_circle_fill,
          color: widget.isStreaming
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
        onSuffixTap: widget.isStreaming
            ? widget.onStop
            : () async {
                if (_recording) {
                  final text = widget.controller.text.trim();
                  await widget.audioService.stop();
                  _asrSub?.cancel();
                  _asrSub = null;
                  widget.controller.clear();
                  if (mounted) setState(() => _recording = false);
                  if (text.isNotEmpty) await widget.onSend(text);
                } else {
                  await widget.onSend();
                }
              },
      ),
    );
  }
}
