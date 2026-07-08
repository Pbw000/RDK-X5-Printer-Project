import 'package:flutter/foundation.dart';
import '../models/print_file.dart';
import '../models/location.dart';
import 'api_service.dart';
import 'job_store.dart';

/// Central store for files that have been uploaded but not yet submitted.
///
/// Mirrors the `JobStore` pattern: singleton + ChangeNotifier, so both the UI
/// (HomeScreen) and the agent tools can access and mutate the same state.
class PendingFileStore extends ChangeNotifier {
  static final PendingFileStore _instance = PendingFileStore._();
  static PendingFileStore get instance => _instance;
  PendingFileStore._();

  final List<PrintFile> _files = [];
  List<Location> _locations = [];

  /// All uploaded, not-yet-submitted files.
  List<PrintFile> get files => List.unmodifiable(_files);

  /// All known delivery locations (cached from the backend).
  List<Location> get locations => List.unmodifiable(_locations);

  /// Whether a submit operation is currently in progress.
  bool isSubmitting = false;

  // ── Init ─────────────────────────────────────────────────────────

  Future<void> init() async {
    await loadLocations();
  }

  Future<void> loadLocations() async {
    try {
      _locations = await ApiService.instance.getLocations();
      notifyListeners();
    } catch (e) {
      debugPrint('[PendingFileStore] Failed to load locations: $e');
    }
  }

  // ── File operations ──────────────────────────────────────────────

  void addFile(PrintFile file) {
    _files.add(file);
    notifyListeners();
  }

  void removeFile(String storedName) {
    _files.removeWhere((f) => f.storedName == storedName);
    notifyListeners();
  }

  void removeFiles(List<String> storedNames) {
    final toRemove = storedNames.toSet();
    _files.removeWhere((f) => toRemove.contains(f.storedName));
    notifyListeners();
  }

  void updateFile(String storedName, PrintFile updated) {
    final idx = _files.indexWhere((f) => f.storedName == storedName);
    if (idx >= 0) {
      _files[idx] = updated;
      notifyListeners();
    }
  }

  /// Replace the file at a specific index (used when placeholder's storedName
  /// differs from the uploaded file's UUID-based storedName).
  void replaceFileAt(int index, PrintFile updated) {
    if (index >= 0 && index < _files.length) {
      _files[index] = updated;
      notifyListeners();
    }
  }

  void updatePriority(String storedName, PrintPriority priority) {
    final idx = _files.indexWhere((f) => f.storedName == storedName);
    if (idx >= 0) {
      _files[idx].priority.value = priority;
      notifyListeners();
    }
  }

  void clearFiles() {
    _files.clear();
    notifyListeners();
  }

  /// Submit all pending files to the given [locationId].
  ///
  /// Calls the backend, then persists the jobs via [JobStore].
  /// Returns the number of jobs successfully submitted.
  Future<int> submitAll(int locationId) async {
    if (_files.isEmpty) return 0;

    final location = _locations.where((l) => l.id == locationId).firstOrNull;
    final locationName = location?.name ?? 'ID:$locationId';

    isSubmitting = true;
    notifyListeners();

    try {
      await ApiService.instance.submitJobs(locationId, _files);
      await JobStore.instance.addSubmittedJobs(
        files: List.from(_files),
        locationId: locationId,
        locationName: locationName,
      );
      final count = _files.length;
      _files.clear();
      return count;
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }
}
