import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/job.dart';

/// SSE client — connects to `GET /api/events`.
///
/// Exposes a broadcast [stream] so multiple consumers (JobStore,
/// PrinterStateService, etc.) can subscribe simultaneously.
/// The underlying HTTP connection is kept alive as long as at least
/// one listener is active and auto-reconnects on error / disconnect.
class SseService {
  static final SseService _instance = SseService._();
  static SseService get instance => _instance;
  SseService._();

  String baseUrl = 'https://your-server.example.com';

  http.Client? _client;
  StreamSubscription<String>? _subscription;
  bool _disposed = false;

  final StreamController<SseEvent> _controller =
      StreamController<SseEvent>.broadcast();

  /// Broadcast stream of parsed SSE events.  Multiple listeners allowed.
  Stream<SseEvent> get stream => _controller.stream;

  /// Open the SSE connection if not already connected.
  void connect() {
    if (_subscription != null || _disposed) return;

    _client = http.Client();
    final request = http.Request('GET', Uri.parse('$baseUrl/api/events'));
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';

    _client!
        .send(request)
        .then((response) {
          _subscription = response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  final event = parseSseLine(line);
                  if (event != null) _controller.add(event);
                },
                onError: (_) {
                  _scheduleReconnect();
                },
                onDone: () => _scheduleReconnect(),
              );
        })
        .catchError((_) {
          _scheduleReconnect();
        });
  }

  void _scheduleReconnect() {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
    if (_disposed) return;
    Future.delayed(const Duration(seconds: 3), connect);
  }

  /// Stop the underlying HTTP connection and release resources.
  void cancel() {
    _disposed = true;
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }
}
