import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Minimal streaming ASR service.
///
/// Connects to StepFun bidirectional streaming ASR via WebSocket,
/// auto-starts recording, and emits recognised text through [textStream].
class AudioService {
  static final AudioService _instance = AudioService._();
  static AudioService get instance => _instance;
  AudioService._();

  // ─── Config ───────────────────────────────────────────────
  static const _wsUrl = 'wss://api.stepfun.com/v1/realtime/asr/stream';
  static const _model = 'stepaudio-2.5-asr-stream';

  String apiKey =
      'Your api key';
  String language = 'zh';

  // ─── State ────────────────────────────────────────────────
  bool _isRecording = false;
  bool get isRecording => _isRecording;

  String _currentText = '';
  String get currentText => _currentText;

  final _textController = StreamController<String>.broadcast();

  /// Real-time transcription text stream (delta + completed).
  Stream<String> get textStream => _textController.stream;

  // ─── Internals ────────────────────────────────────────────
  WebSocket? _ws;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  int _eventCounter = 0;

  // ─── Public API ───────────────────────────────────────────

  /// Connect WebSocket, configure session, and start recording.
  Future<void> start() async {
    if (_isRecording) return;
    if (apiKey.isEmpty) throw StateError('apiKey not set');

    try {
      // 1. WebSocket
      _ws = await WebSocket.connect(
        _wsUrl,
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      // 2. Session config
      _send({
        'type': 'session.update',
        'session': {
          'audio': {
            'input': {
              'format': {
                'type': 'pcm',
                'codec': 'pcm_s16le',
                'rate': 16000,
                'bits': 16,
                'channel': 1,
              },
              'transcription': {'model': _model, 'language': language},
              'turn_detection': {
                'type': 'server_vad',
                'silence_duration_ms': 800,
                'threshold': 0.5,
              },
            },
          },
        },
      });

      // 3. Listen to server messages
      _ws!.listen(_onMessage, onError: _onError, onDone: _onDone);

      // 4. Mic permission + start stream
      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission denied');
      }

      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      // 5. Pipe PCM chunks → base64 → WebSocket
      _audioSub = audioStream.listen((chunk) {
        if (_ws?.readyState == WebSocket.open) {
          _send({
            'type': 'input_audio_buffer.append',
            'audio': base64Encode(chunk),
          });
        }
      });

      _isRecording = true;
      _currentText = '';
    } catch (e) {
      _cleanup();
      rethrow;
    }
  }

  /// Stop recording and close WebSocket.
  Future<void> stop() async {
    await _cleanup();
  }

  void dispose() {
    _cleanup();
    _textController.close();
  }

  // ─── Server message handling ──────────────────────────────

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';

      switch (type) {
        // delta: cumulative text — replace, don't append
        case 'conversation.item.input_audio_transcription.delta':
          final text = json['text'] as String? ?? '';
          if (text.isNotEmpty) {
            _currentText = text;
            _textController.add(text);
          }

        // completed: final segment text
        case 'conversation.item.input_audio_transcription.completed':
          final transcript = json['transcript'] as String? ?? '';
          if (transcript.isNotEmpty) {
            _currentText = transcript;
            _textController.add(transcript);
          }

        case 'error':
          final msg = (json['error'] as Map?)?['message'] ?? 'unknown';
          debugPrint('[ASR] error: $msg');
          _textController.addError(msg);
      }
    } catch (_) {
      // ignore malformed frames
    }
  }

  void _onError(dynamic error) {
    debugPrint('[ASR] ws error: $error');
    _textController.addError(error);
    _cleanup();
  }

  void _onDone() {
    debugPrint('[ASR] ws closed');
    _cleanup();
  }

  // ─── Helpers ──────────────────────────────────────────────

  void _send(Map<String, dynamic> msg) {
    if (_ws?.readyState != WebSocket.open) return;
    msg['event_id'] = 'evt_${++_eventCounter}';
    _ws!.add(jsonEncode(msg));
  }

  Future<void> _cleanup() async {
    _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    if (_isRecording) {
      _isRecording = false;
    }
  }
}
