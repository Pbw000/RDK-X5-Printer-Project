import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';
import '../models/location.dart';
import '../models/print_file.dart';
import '../models/job.dart';

class ApiService {
  static final ApiService _instance = ApiService._();
  static ApiService get instance => _instance;
  ApiService._();

  String baseUrl = 'https://your-server.example.com';

  Future<bool> healthCheck() async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/health'));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Location>> getLocations() async {
    final res = await http.get(Uri.parse('$baseUrl/api/locations'));
    if (res.statusCode != 200) {
      throw ApiException('Failed to load locations', res.statusCode);
    }

    final body = jsonDecode(res.body);
    if (body is Map<String, dynamic>) {
      return PrintDests.fromJson(body).destinations;
    }
    if (body is List) {
      return body
          .asMap()
          .entries
          .map(
            (e) =>
                Location.fromJson(e.value as Map<String, dynamic>, id: e.key),
          )
          .toList();
    }
    throw ApiException('Unexpected locations format', res.statusCode);
  }

  Future<PrintFile> uploadFile(
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final fileName = file.uri.pathSegments.last;
    final fileSize = await file.length();

    // Cache file to local temp directory for preview.
    final cacheDir = await getTemporaryDirectory();
    final previewDir = Directory(p.join(cacheDir.path, 'printer_preview'));
    if (!await previewDir.exists()) {
      await previewDir.create(recursive: true);
    }

    // Build a progress-tracking byte stream from the file.
    final rawStream = file.openRead();
    int bytesSent = 0;
    final trackedStream = rawStream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (data, sink) {
          bytesSent += data.length;
          if (fileSize > 0) {
            onProgress?.call((bytesSent / fileSize).clamp(0.0, 1.0));
          }
          sink.add(data);
        },
        handleError: (error, stack, sink) => sink.addError(error),
        handleDone: (sink) {
          onProgress?.call(1.0);
          sink.close();
        },
      ),
    );

    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/upload'));
    req.files.add(
      http.MultipartFile('file', trackedStream, fileSize, filename: fileName),
    );
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);

    if (res.statusCode != 200) {
      throw ApiException('Upload failed: ${res.body}', res.statusCode);
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final storedName = body['stored_name'] as String;
    final localPath = p.join(previewDir.path, storedName);
    await file.copy(localPath);
    return PrintFile(
      storedName: storedName,
      displayName: fileName,
      size: body['file_size'] as int? ?? fileSize,
      localPath: localPath,
    );
  }

  Future<List<JobResponse>> submitJobs(
    int locationId,
    List<PrintFile> files,
  ) async {
    final body = {
      'location_id': locationId,
      'tasks': files
          .map(
            (f) => {
              'stored_name': f.storedName,
              'priority': f.priority.value.toJson(),
            },
          )
          .toList(),
    };

    final res = await http.post(
      Uri.parse('$baseUrl/api/jobs'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (res.statusCode != 200) {
      throw ApiException('Submit failed: ${res.body}', res.statusCode);
    }

    final decoded = jsonDecode(res.body);
    if (decoded is List) {
      return decoded
          .map((e) => JobResponse.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [JobResponse.fromJson(decoded as Map<String, dynamic>)];
  }

  Future<PrinterStatus> getPrinterStatus() async {
    final res = await http.get(Uri.parse('$baseUrl/api/printer/status'));
    if (res.statusCode != 200) return PrinterStatus.unknown;

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return parsePrinterStatusResponse(body);
  }

  /// Rich printer status with printing progress (total/processed).
  Future<PrinterStatusInfo> getPrinterStatusInfo() async {
    final res = await http.get(Uri.parse('$baseUrl/api/printer/status'));
    if (res.statusCode != 200) {
      return const PrinterStatusInfo(status: PrinterStatus.unknown);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return parsePrinterStatusInfoResponse(body);
  }

  /// Returns `null` when the backend is unreachable (connection error).
  Future<FileState?> getFileStatus(String fileId) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/api/files/$fileId/status'),
      );
      if (res.statusCode != 200) return FileState.removed;
      final body = jsonDecode(res.body);
      if (body is String) return FileState.fromString(body);
      return FileState.removed;
    } catch (_) {
      return null;
    }
  }

  Future<NavigationStatus> getNavigationStatus() async {
    final res = await http.get(Uri.parse('$baseUrl/api/navigation/status'));
    if (res.statusCode != 200) return const NavigationStatus([]);

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return NavigationStatus.fromJson(body);
  }

  /// POST to auth server on port 3001 to confirm batch pickup.
  Future<bool> confirmCompletion() async {
    try {
      final uri = Uri.parse(baseUrl);
      final authUrl = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: 3001,
        path: '/api/complete',
      );
      final res = await http.post(authUrl);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<PositionUpdate> getPrinterPosition() async {
    final res = await http.get(Uri.parse('$baseUrl/api/printer/position'));
    if (res.statusCode != 200) {
      throw ApiException('Position fetch failed', res.statusCode);
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return PositionUpdate(
      x: (body['x'] as num?)?.toDouble() ?? 0,
      y: (body['y'] as num?)?.toDouble() ?? 0,
      theta: (body['theta'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Fetches the map snapshot from `GET /api/map`.
  ///
  /// Response format (flat MapSnapshot):
  /// ```json
  /// { "width": 4000, "height": 4000, "resolution": 0.05,
  ///   "origin_x": -100, "origin_y": -100, "origin_theta": 0,
  ///   "data": "<base64>" }
  /// ```
  Future<MapUpdate?> getMap() async {
    final res = await http.get(Uri.parse('$baseUrl/api/map'));
    if (res.statusCode != 200) return null;

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return MapUpdate(
      width: body['width'] as int? ?? 0,
      height: body['height'] as int? ?? 0,
      resolution: (body['resolution'] as num?)?.toDouble() ?? 0,
      originX: (body['origin_x'] as num?)?.toDouble() ?? 0,
      originY: (body['origin_y'] as num?)?.toDouble() ?? 0,
      originTheta: (body['origin_theta'] as num?)?.toDouble() ?? 0,
      data: body['data'] as String? ?? '',
    );
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;
  const ApiException(this.message, this.statusCode);
  @override
  String toString() => 'ApiException($statusCode): $message';
}
