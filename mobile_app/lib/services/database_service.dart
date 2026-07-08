import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/local_job.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._();
  static DatabaseService get instance => _instance;
  DatabaseService._();

  Database? _db;

  Future<void> init() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'printer_client.db');

    _db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE local_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        stored_name TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        location_id INTEGER NOT NULL,
        location_name TEXT NOT NULL,
        priority TEXT NOT NULL DEFAULT 'medium',
        file_size INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'submitted',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_status ON local_jobs(status)');
    await db.execute('CREATE INDEX idx_location ON local_jobs(location_id)');
  }

  Database get db {
    if (_db == null) throw StateError('DatabaseService.init() not called');
    return _db!;
  }

  Future<void> insertJob(LocalJob job) async {
    await db.insert(
      'local_jobs',
      job.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateStatus(String storedName, JobStatus status) async {
    await db.update(
      'local_jobs',
      {
        'status': status.toJson(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'stored_name = ?',
      whereArgs: [storedName],
    );
  }

  Future<void> updateStatusByLocation(int locationId, JobStatus status) async {
    await db.update(
      'local_jobs',
      {
        'status': status.toJson(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'location_id = ? AND status IN (?, ?)',
      whereArgs: [
        locationId,
        JobStatus.submitted.toJson(),
        JobStatus.printing.toJson(),
      ],
    );
  }

  Future<List<LocalJob>> getAllJobs() async {
    final rows = await db.query(
      'local_jobs',
      orderBy:
          'CASE status '
          "WHEN 'printing' THEN 0 "
          "WHEN 'submitted' THEN 1 "
          "WHEN 'completed' THEN 2 "
          "WHEN 'confirmed' THEN 3 "
          "WHEN 'failed' THEN 4 "
          'ELSE 5 END, '
          'updated_at DESC',
    );
    return rows.map(LocalJob.fromMap).toList();
  }

  Future<List<LocalJob>> getActiveJobs() async {
    final rows = await db.query(
      'local_jobs',
      where: 'status IN (?, ?)',
      whereArgs: [JobStatus.submitted.toJson(), JobStatus.printing.toJson()],
      orderBy: 'created_at DESC',
    );
    return rows.map(LocalJob.fromMap).toList();
  }

  /// Jobs with status = 'completed' (printed, waiting for user action).
  Future<List<LocalJob>> getCompletedJobs() async {
    final rows = await db.query(
      'local_jobs',
      where: 'status = ?',
      whereArgs: [JobStatus.completed.toJson()],
      orderBy: 'updated_at DESC',
    );
    return rows.map(LocalJob.fromMap).toList();
  }

  /// Delete a job from the database entirely.
  Future<void> deleteJob(String storedName) async {
    await db.delete(
      'local_jobs',
      where: 'stored_name = ?',
      whereArgs: [storedName],
    );
  }

  Future<List<LocalJob>> getJobsByLocation(int locationId) async {
    final rows = await db.query(
      'local_jobs',
      where: 'location_id = ?',
      whereArgs: [locationId],
      orderBy: 'created_at DESC',
    );
    return rows.map(LocalJob.fromMap).toList();
  }

  Future<int> cleanupOldJobs({
    Duration maxAge = const Duration(days: 7),
  }) async {
    final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
    return await db.delete(
      'local_jobs',
      where:
          "status IN ('completed', 'confirmed', 'failed') AND updated_at < ?",
      whereArgs: [cutoff],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
