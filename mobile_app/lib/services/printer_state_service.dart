import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/job.dart';
import 'sse_service.dart';

/// Global printer state — position, status, online flag, event log.
///
/// Updated in real-time via the SSE broadcast stream.
/// Any widget can `context.watch<PrinterStateService>()` to react.
class PrinterStateService extends ChangeNotifier {
  static final PrinterStateService _instance = PrinterStateService._();
  static PrinterStateService get instance => _instance;
  PrinterStateService._();

  StreamSubscription<SseEvent>? _sub;
  Timer? _onlineTimer;

  // ── Observable state ───────────────────────────────────────────

  final position = ValueNotifier<PositionUpdate?>(null);
  PrinterStatusInfo _statusInfo = const PrinterStatusInfo(
    status: PrinterStatus.unknown,
  );
  bool _online = false;
  final List<SseEvent> _eventLog = [];
  PrinterStatusInfo get statusInfo => _statusInfo;
  bool get online => _online;

  /// Most recent meaningful events (newest first), excluding noisy ticks.
  List<SseEvent> get recentEvents => List.unmodifiable(_eventLog);

  // ── Lifecycle ──────────────────────────────────────────────────

  /// Start listening to SSE.  Safe to call multiple times.
  void startListening() {
    if (_sub != null) return;
    SseService.instance.connect();
    _sub = SseService.instance.stream.listen(_handleEvent);
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
    _onlineTimer?.cancel();
    _onlineTimer = null;
  }

  @override
  void dispose() {
    stopListening();
    position.dispose();
    super.dispose();
  }

  // ── Event handling ─────────────────────────────────────────────

  void _handleEvent(SseEvent event) {
    _markOnline();

    // Position tracking — ValueNotifier handles granular updates
    if (event is PositionUpdate) {
      position.value = event;
      return; // too noisy for the event log
    }

    // Status tracking
    switch (event) {
      case MovingTo():
        _statusInfo = const PrinterStatusInfo(status: PrinterStatus.moving);
      case MoveComplete():
        _statusInfo = const PrinterStatusInfo(status: PrinterStatus.idle);
      case BatchStarted() || PrintStarted():
        _statusInfo = const PrinterStatusInfo(status: PrinterStatus.printing);
      case IdleEvent():
        _statusInfo = const PrinterStatusInfo(status: PrinterStatus.idle);
      case SchedulerError() || NavError():
        _statusInfo = const PrinterStatusInfo(status: PrinterStatus.error);
      default:
        break;
    }

    // Event log (exclude high-frequency noise)
    if (event is! ConfirmTick) {
      _eventLog.insert(0, event);
      if (_eventLog.length > 50) _eventLog.removeLast();
    }

    notifyListeners();
  }

  void _markOnline() {
    final wasOnline = _online;
    _online = true;
    _onlineTimer?.cancel();
    _onlineTimer = Timer(const Duration(seconds: 10), () {
      _online = false;
      notifyListeners();
    });
    if (!wasOnline) notifyListeners();
  }
}
