import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/job.dart';
import '../models/local_job.dart';
import '../services/job_store.dart';

enum QueueSegment { waiting, queued, completed }

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final ValueNotifier<QueueSegment> _segment = ValueNotifier(
    QueueSegment.waiting,
  );
  bool _firstLoad = true;

  @override
  void dispose() {
    _segment.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.watch<JobStore>();

    if (_firstLoad) {
      _firstLoad = false;
      _autoSegment(store);
      return;
    }

    // If current segment is empty, switch to highest-priority non-empty.
    final jobs = _jobsForSegment(store, _segment.value);
    if (jobs.isEmpty) {
      _autoSegment(store);
    }
  }

  /// Select the highest-priority non-empty segment.
  void _autoSegment(JobStore store) {
    if (store.waitingJobs.isNotEmpty) {
      _segment.value = QueueSegment.waiting;
    } else if (store.queuedJobs.isNotEmpty) {
      _segment.value = QueueSegment.queued;
    } else {
      _segment.value = QueueSegment.completed;
    }
  }

  List<LocalJob> _jobsForSegment(JobStore store, QueueSegment segment) {
    return switch (segment) {
      QueueSegment.waiting => store.waitingJobs,
      QueueSegment.queued => store.queuedJobs,
      QueueSegment.completed => store.confirmedJobs,
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<JobStore>();
    final theme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        // ── Header ──────────────────────────────────────
        SliverAppBar(
          pinned: true,
          expandedHeight: 120,
          toolbarHeight: 52,
          automaticallyImplyLeading: false,
          backgroundColor: theme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            ValueListenableBuilder<QueueSegment>(
              valueListenable: _segment,
              builder: (context, segment, _) {
                if (segment != QueueSegment.completed ||
                    store.confirmedJobs.isEmpty) {
                  return const SizedBox.shrink();
                }
                return TextButton.icon(
                  onPressed: () => store.clearConfirmed(),
                  icon: Icon(
                    Icons.cleaning_services_outlined,
                    size: 18,
                    color: theme.onSurface.withValues(alpha: 0.54),
                  ),
                  label: Text(
                    '清理',
                    style: TextStyle(
                      color: theme.onSurface.withValues(alpha: 0.54),
                    ),
                  ),
                );
              },
            ),
          ],
          flexibleSpace: LayoutBuilder(
            builder: (context, constraints) {
              final topPadding = MediaQuery.of(context).padding.top;
              final available = constraints.biggest.height - topPadding;
              const maxH = 120.0;
              const minH = 52.0;
              final t = ((available - minH) / (maxH - minH)).clamp(0.0, 1.0);
              final fontSize = 20.0 + 8.0 * t;
              final top = topPadding + 12.0 + 8.0 * t;
              return Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.only(top: top, left: 20, right: 20),
                  child: Text(
                    '队列',
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.bold,
                      color: theme.onSurface,
                      height: 1,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // ── SegmentedButton ─────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ValueListenableBuilder<QueueSegment>(
              valueListenable: _segment,
              builder: (context, selected, _) {
                return SegmentedButton<QueueSegment>(
                  segments: [
                    ButtonSegment(
                      value: QueueSegment.waiting,
                      label: Text('待取件 ${store.waitingJobs.length}'),
                      icon: const Icon(Icons.inventory_2_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: QueueSegment.queued,
                      label: Text('队列中 ${store.queuedJobs.length}'),
                      icon: const Icon(Icons.queue_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: QueueSegment.completed,
                      label: Text('已完成 ${store.confirmedJobs.length}'),
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                    ),
                  ],
                  selected: {selected},
                  onSelectionChanged: (s) => _segment.value = s.first,
                  showSelectedIcon: false,
                );
              },
            ),
          ),
        ),

        // ── Job list / empty state ────────────────────
        ValueListenableBuilder<QueueSegment>(
          valueListenable: _segment,
          builder: (context, segment, _) {
            final jobs = _jobsForSegment(store, segment);
            if (jobs.isNotEmpty) {
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _JobCard(job: jobs[i]),
                  childCount: jobs.length,
                ),
              );
            }
            final allEmpty =
                store.waitingJobs.isEmpty &&
                store.queuedJobs.isEmpty &&
                store.confirmedJobs.isEmpty;
            return SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.surfaceContainerHighest,
                      ),
                      child: Icon(
                        Icons.inbox_outlined,
                        size: 32,
                        color: theme.onSurface.withValues(alpha: 0.3),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      allEmpty ? '暂无打印任务' : _emptyMsg(segment),
                      style: TextStyle(
                        color: theme.onSurface.withValues(alpha: 0.5),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (allEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '在首页上传文件开始使用',
                        style: TextStyle(
                          color: theme.onSurface.withValues(alpha: 0.35),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  static String _emptyMsg(QueueSegment s) => switch (s) {
    QueueSegment.waiting => '暂无待取件',
    QueueSegment.queued => '队列为空',
    QueueSegment.completed => '暂无已完成',
  };
}

// ─── Job Card ─────────────────────────────────────────────────────
class _JobCard extends StatelessWidget {
  final LocalJob job;
  const _JobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    final fileState = context.read<JobStore>().fileStates[job.storedName];
    final statusColor = fileState != null
        ? fileState.color(theme)
        : job.status.color(theme);

    return Card(
      elevation: 3,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: SizedBox(
          width: 40,
          height: 48,
          child: Image.asset(job.fileIcon, fit: BoxFit.fill),
        ),
        title: Text(
          job.displayName,
          style: TextStyle(
            color: theme.onSurface,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 13,
              color: theme.onSurface.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 3),
            Text(
              job.locationName,
              style: TextStyle(
                fontSize: 12,
                color: theme.onSurface.withValues(alpha: 0.45),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '·',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
            Text(
              job.formattedSize,
              style: TextStyle(
                fontSize: 12,
                color: theme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
        trailing: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StatusBadge(
              status: job.status,
              fileState: fileState,
              color: statusColor,
            ),
            const SizedBox(height: 6),
            Text(
              _timeAgo(job.updatedAt),
              style: TextStyle(
                fontSize: 11,
                color: theme.onSurface.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Status Badge ────────────────────────────────────────────────
class _StatusBadge extends StatelessWidget {
  final JobStatus status;
  final FileState? fileState;
  final Color color;
  const _StatusBadge({
    required this.status,
    this.fileState,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final label = fileState != null ? fileState!.label : status.label;
    final icon = fileState != null ? fileState!.icon : status.icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 10) return '刚刚';
  if (d.inSeconds < 60) return '${d.inSeconds} 秒前';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}
