import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/local_job.dart';
import '../models/job.dart';
import '../models/print_file.dart';
import 'database_service.dart';
import 'sse_service.dart';
import 'api_service.dart';

/// Central state store for local print jobs.
///
/// Loads from SQLite on startup, listens to SSE events, and exposes
/// reactive job lists segmented by status for the Queue UI.
///
/// "已完成" jobs are **removed from DB** and kept only in [_confirmedJobs].
class JobStore extends ChangeNotifier {
  static final JobStore _instance = JobStore._();
  static JobStore get instance => _instance;
  JobStore._();

  final _db = DatabaseService.instance;

  /// Jobs that still live in the database (submitted / printing / completed).
  List<LocalJob> _jobs = [];

  /// Finished jobs — removed from DB, kept in memory only.
  List<LocalJob> _confirmedJobs = [];

  /// Server-side file states, keyed by storedName.
  final Map<String, FileState> _fileStates = {};
  StreamSubscription<SseEvent>? _sseSub;

  // ── Segment getters ────────────────────────────────────────────

  /// 队列中 — active jobs (submitted / printing), excluding removed files.
  List<LocalJob> get queuedJobs => _jobs
      .where(
        (j) => j.isActive && _fileStates[j.storedName] != FileState.removed,
      )
      .toList();

  /// 待取件 — printed, waiting for user to pick up (based on server file state).
  List<LocalJob> get waitingJobs => _jobs
      .where((j) => _fileStates[j.storedName] == FileState.waitingForPickUp)
      .toList();

  /// 已完成 — confirmed/failed in memory + DB jobs whose files are removed on backend.
  List<LocalJob> get confirmedJobs {
    final removedInDb = _jobs
        .where((j) => _fileStates[j.storedName] == FileState.removed)
        .toList();
    return List.unmodifiable([..._confirmedJobs, ...removedInDb]);
  }

  Map<String, FileState> get fileStates => _fileStates;

  // ── Init ───────────────────────────────────────────────────────

  Future<void> init() async {
    final active = await _db.getActiveJobs();
    final completed = await _db.getCompletedJobs();
    _jobs = [...active, ...completed];
    await _loadAllFileStates();
    notifyListeners();
    SseService.instance.connect();
    _sseSub = SseService.instance.stream.listen(_handleEvent);
  }

  // ── Submit ─────────────────────────────────────────────────────

  Future<void> addSubmittedJobs({
    required List<PrintFile> files,
    required int locationId,
    required String locationName,
  }) async {
    final now = DateTime.now();
    for (final file in files) {
      final job = LocalJob(
        storedName: file.storedName,
        displayName: file.displayName,
        locationId: locationId,
        locationName: locationName,
        priority: file.priority.value,
        fileSize: file.size,
        createdAt: now,
        updatedAt: now,
      );
      await _db.insertJob(job);
    }
    await _reloadJobs();
    // Load file status once for newly submitted jobs.
    for (final file in files) {
      final state = await ApiService.instance.getFileStatus(file.storedName);
      if (state != null) _fileStates[file.storedName] = state;
    }
    notifyListeners();
  }

  // ── File state loading (once at init + once per submit) ────────

  /// Load file state for all DB jobs; remove from DB any that the
  /// backend has already finished with (FileState.removed).
  Future<void> _loadAllFileStates() async {
    for (final job in _jobs) {
      final state = await ApiService.instance.getFileStatus(job.storedName);
      if (state != null) {
        _fileStates[job.storedName] = state;
      }
    }
    // Batch-delete jobs whose files are gone from the backend.
    final removed = _jobs
        .where((j) => _fileStates[j.storedName] == FileState.removed)
        .toList();
    if (removed.isNotEmpty) {
      for (final job in removed) {
        await _db.deleteJob(job.storedName);
        _confirmedJobs.insert(
          0,
          job.copyWith(status: JobStatus.confirmed, updatedAt: DateTime.now()),
        );
        _fileStates.remove(job.storedName);
      }
      await _reloadJobs();
    }
  }

  // ── SSE event handler ──────────────────────────────────────────

  void _handleEvent(SseEvent event) {
    switch (event) {
      case BatchStarted():
        _updateByLocation(event.locationId, JobStatus.printing);
      case PrintStarted():
        _fileStates[event.storeName] = FileState.printing;
        _updateByName(event.storeName, JobStatus.printing);
      case PrintComplete():
        _fileStates[event.storeName] = FileState.waitingForPickUp;
        _updateByName(event.storeName, JobStatus.completed);
      case PrintFailed():
        _fileStates.remove(event.storeName);
        _removeJob(event.storeName, JobStatus.failed);
      case ConfirmTick():
      case BatchComplete():
      case MovingTo():
      case MoveComplete():
      case IdleEvent():
      case SchedulerError():
      case NavError():
      case PositionUpdate():
      case MapUpdate():
      case UnknownEvent():
        break;
    }
  }

  // ── DB helpers ─────────────────────────────────────────────────

  Future<void> _reloadJobs() async {
    final active = await _db.getActiveJobs();
    final completed = await _db.getCompletedJobs();
    _jobs = [...active, ...completed];
  }

  Future<void> _updateByLocation(int locationId, JobStatus status) async {
    await _db.updateStatusByLocation(locationId, status);
    await _reloadJobs();
    notifyListeners();
  }

  Future<void> _updateByName(String storedName, JobStatus status) async {
    if (!_jobs.any((j) => j.storedName == storedName)) return;
    await _db.updateStatus(storedName, status);
    await _reloadJobs();
    notifyListeners();
  }

  /// Delete a job from DB and move it to the in-memory confirmed list.
  Future<void> _removeJob(String storedName, JobStatus finalStatus) async {
    final idx = _jobs.indexWhere((j) => j.storedName == storedName);
    if (idx == -1) return;
    final job = _jobs.removeAt(idx);
    await _db.deleteJob(storedName);
    _confirmedJobs.insert(
      0,
      job.copyWith(status: finalStatus, updatedAt: DateTime.now()),
    );
    _fileStates.remove(storedName);
    notifyListeners();
  }

  /// Move all completed / failed DB jobs → in-memory confirmed list.
  Future<void> _confirmAllActive() async {
    final done = _jobs
        .where((j) => j.status.isCompleted || j.status.isFailed)
        .toList();
    if (done.isEmpty) return;
    for (final job in done) {
      await _db.deleteJob(job.storedName);
      _confirmedJobs.insert(
        0,
        job.copyWith(status: JobStatus.confirmed, updatedAt: DateTime.now()),
      );
      _fileStates.remove(job.storedName);
    }
    await _reloadJobs();
    notifyListeners();
  }

  Future<bool> confirmCompletion() async {
    final result = await ApiService.instance.confirmCompletion();
    if (result) await _confirmAllActive();
    return result;
  }

  /// Clear in-memory confirmed jobs.
  void clearConfirmed() {
    _confirmedJobs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    super.dispose();
  }
}
