import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/job.dart';
import '../models/location.dart';
import '../services/api_service.dart';
import '../services/printer_state_service.dart';
import '../widgets/location_map_widget.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  List<Location> _locations = [];

  @override
  void initState() {
    super.initState();
    context.read<PrinterStateService>().startListening();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final locs = await ApiService.instance.getLocations();
      if (mounted) setState(() => _locations = locs);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Consumer<PrinterStateService>(
        builder: (context, state, _) {
          return CustomScrollView(
            slivers: [
              // ── App Bar ──────────────────────────────────────────
              SliverAppBar(
                pinned: true,
                backgroundColor: cs.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0.5,
                automaticallyImplyLeading: false,
                centerTitle: false,
                titleSpacing: 20,
                title: const Text('打印机状态'),
              ),

              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                sliver: SliverList.list(
                  children: [
                    // ── Map (position via ValueNotifier) ───────────
                    ValueListenableBuilder<PositionUpdate?>(
                      valueListenable: state.position,
                      builder: (_, pos, __) => LocationMapWidget(
                        locations: _locations,
                        printerPosition: pos,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Connection & status ────────────────────────
                    _StatusCard(
                      online: state.online,
                      statusInfo: state.statusInfo,
                    ),

                    const SizedBox(height: 12),

                    // ── Position (via ValueNotifier) ───────────────
                    ValueListenableBuilder<PositionUpdate?>(
                      valueListenable: state.position,
                      builder: (_, pos, __) => _PositionCard(position: pos),
                    ),

                    const SizedBox(height: 12),

                    // ── Activity log ───────────────────────────────
                    _ActivityCard(events: state.recentEvents),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Status Card ───────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final bool online;
  final PrinterStatusInfo statusInfo;

  const _StatusCard({required this.online, required this.statusInfo});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Online row ───────────────────────────────────────────
          Row(
            spacing: 8,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: online
                      ? const Color(0xFF34C759)
                      : const Color(0xFFFF3B30),
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                online ? '在线' : '离线',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: online
                      ? const Color(0xFF34C759)
                      : const Color(0xFFFF3B30),
                ),
              ),
              const Spacer(),
              _statusChip(cs, statusInfo),
            ],
          ),

          // ── Printing progress ───────────────────────────────────
          if (statusInfo.isPrinting && statusInfo.printingTotal != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: statusInfo.printingTotal! > 0
                    ? statusInfo.printingProcessed! / statusInfo.printingTotal!
                    : null,
                minHeight: 5,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '打印进度 ${statusInfo.printingProcessed}/${statusInfo.printingTotal}',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChip(ColorScheme cs, PrinterStatusInfo info) {
    final (label, color) = switch (info.status) {
      PrinterStatus.idle => ('空闲', const Color(0xFF8E8E93)),
      PrinterStatus.printing => ('打印中', cs.primary),
      PrinterStatus.moving => ('移动中', const Color(0xFFFF9500)),
      PrinterStatus.waitingConfirmation => ('等待确认', const Color(0xFFAF52DE)),
      PrinterStatus.error => ('错误', const Color(0xFFFF3B30)),
      PrinterStatus.unknown => ('未知', const Color(0xFF8E8E93)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─── Position Card ─────────────────────────────────────────────────

class _PositionCard extends StatelessWidget {
  final PositionUpdate? position;
  const _PositionCard({required this.position});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pos = position;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            spacing: 6,
            children: [
              Icon(CupertinoIcons.location_fill, size: 14, color: cs.primary),
              Text(
                '当前位置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          if (pos == null)
            Text(
              '暂无数据',
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.4),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'x ${pos.x.toStringAsFixed(2)}   '
                      'y ${pos.y.toStringAsFixed(2)}   '
                      'θ ${(pos.theta * 180 / 3.14159265).toStringAsFixed(1)}°',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: cs.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Activity Card ─────────────────────────────────────────────────

class _ActivityCard extends StatelessWidget {
  final List<SseEvent> events;
  const _ActivityCard({required this.events});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '活动日志',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              if (events.isNotEmpty)
                Text(
                  '${events.length} 条',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '暂无活动',
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
            )
          else
            ...events.take(20).map((e) => _EventRow(event: e)),
        ],
      ),
    );
  }
}

// ─── Event Row ─────────────────────────────────────────────────────

class _EventRow extends StatelessWidget {
  final SseEvent event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        spacing: 10,
        children: [
          Icon(_iconFor(event), size: 14, color: _colorFor(event, cs)),
          Expanded(
            child: Text(
              _textFor(event),
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _textFor(SseEvent e) => switch (e) {
    BatchStarted() => '开始批次 → ${e.locationName} (${e.totalJobs} 任务)',
    PrintStarted() => '打印 [${e.jobIndex}/${e.totalJobs}] ${e.storeName}',
    PrintComplete() => '✓ ${e.storeName} 完成',
    PrintFailed() => '✗ ${e.storeName}: ${e.msg}',
    BatchComplete() =>
      '批次 ${e.locationName} 完成: ${e.succeeded} 成功, ${e.failed} 失败',
    MovingTo() => '移动中 → ${e.locationName}',
    MoveComplete() => '到达位置 ${e.locationId}',
    IdleEvent() => '空闲',
    SchedulerError() => '调度错误: ${e.msg}',
    NavError() => '导航错误 @ ${e.locationId}: ${e.msg}',
    PositionUpdate() =>
      '位置 (${e.x.toStringAsFixed(1)}, ${e.y.toStringAsFixed(1)})',
    _ => e.toString(),
  };

  static IconData _iconFor(SseEvent e) => switch (e) {
    BatchStarted() => CupertinoIcons.play_fill,
    PrintStarted() => CupertinoIcons.printer,
    PrintComplete() => CupertinoIcons.checkmark_circle,
    PrintFailed() => CupertinoIcons.xmark_circle,
    BatchComplete() => CupertinoIcons.checkmark_seal,
    MovingTo() => CupertinoIcons.location_fill,
    MoveComplete() => CupertinoIcons.checkmark,
    IdleEvent() => CupertinoIcons.pause_circle,
    SchedulerError() || NavError() => CupertinoIcons.exclamationmark_triangle,
    PositionUpdate() => CupertinoIcons.location,
    _ => CupertinoIcons.info_circle,
  };

  static Color _colorFor(SseEvent e, ColorScheme cs) => switch (e) {
    BatchStarted() || PrintStarted() => cs.primary,
    PrintComplete() || MoveComplete() => const Color(0xFF34C759),
    PrintFailed() || SchedulerError() || NavError() => const Color(0xFFFF3B30),
    BatchComplete() => const Color(0xFFAF52DE),
    MovingTo() => const Color(0xFFFF9500),
    _ => cs.onSurface.withValues(alpha: 0.4),
  };
}
