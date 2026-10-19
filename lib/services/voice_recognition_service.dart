import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'offline_chinese_recognizer.dart';
import 'offline_voice_model.dart';

/// Lifecycle tests use these interfaces without loading native microphone APIs.
abstract class VoiceAudioInput {
  Future<bool> hasPermission({bool request = true});
  Future<Stream<Uint8List>> startStream();
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

abstract class VoiceOfflineRecognizer {
  Future<void> initialize(Map<String, String> paths);
  Future<void> start();
  Future<String> acceptPcm16(Uint8List bytes);
  Future<String> finish();
  Future<void> cancel();
  Future<void> dispose();
}

class _RecordAudioInput implements VoiceAudioInput {
  final AudioRecorder _recorder = AudioRecorder();
  @override
  Future<bool> hasPermission({bool request = true}) => _recorder.hasPermission(request: request);
  @override
  Future<Stream<Uint8List>> startStream() => _recorder.startStream(const RecordConfig(
    encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
  @override
  Future<void> stop() async { await _recorder.stop(); }
  @override
  Future<void> cancel() => _recorder.cancel();
  @override
  Future<void> dispose() => _recorder.dispose();
}

class _LocalRecognizer implements VoiceOfflineRecognizer {
  final OfflineChineseRecognizer _recognizer = OfflineChineseRecognizer();
  @override
  Future<void> initialize(Map<String, String> paths) => _recognizer.initialize(paths);
  @override
  Future<void> start() => _recognizer.start();
  @override
  Future<String> acceptPcm16(Uint8List bytes) => _recognizer.acceptPcm16(bytes);
  @override
  Future<String> finish() => _recognizer.finish();
  @override
  Future<void> cancel() => _recognizer.cancel();
  @override
  Future<void> dispose() => _recognizer.dispose();
}

class _VoiceCapture {
  final int id;
  VoiceAudioInput? input;
  StreamSubscription<Uint8List>? subscription;
  final streamDone = Completer<void>();
  Timer? timer;
  Future<void> recorderWork = Future<void>.value();
  Future<void> engineWork = Future<void>.value();
  Future<void> pcmWork = Future<void>.value();
  Future<void>? release;
  Future<void>? finishing;
  bool cancelled = false;
  bool engineStarted = false;
  bool streamClosed = false;
  bool stopping = false;
  int bytes = 0;
  _VoiceCapture(this.id);
}

class VoiceRecognitionService extends ChangeNotifier {
  VoiceRecognitionService._()
      : _prepare = OfflineVoiceModel.prepare, _recognizer = _LocalRecognizer(),
        _createInput = (() => _RecordAudioInput()), _supportedOverride = null,
        _recordingLimit = const Duration(seconds: 30);

  @visibleForTesting
  VoiceRecognitionService.forTesting({
    required Future<Map<String, String>> Function() prepare,
    required VoiceOfflineRecognizer recognizer,
    required VoiceAudioInput Function() createInput,
    bool supported = true,
    Duration recordingLimit = const Duration(seconds: 30),
  }) : _prepare = prepare, _recognizer = recognizer, _createInput = createInput,
       _supportedOverride = supported, _recordingLimit = recordingLimit;

  static final instance = VoiceRecognitionService._();
  final Future<Map<String, String>> Function() _prepare;
  final VoiceOfflineRecognizer _recognizer;
  final VoiceAudioInput Function() _createInput;
  final bool? _supportedOverride;
  final Duration _recordingLimit;
  Future<void>? _initialization;
  Future<void> _cleanup = Future<void>.value();
  _VoiceCapture? _active;
  int _session = 0;
  bool _askedPermission = false;
  bool _disposed = false;
  String words = '';
  String? error;
  bool starting = false;
  bool initializing = false;
  bool listening = false;
  bool processing = false;

  bool get supported => _supportedOverride ?? (!kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));
  bool _current(_VoiceCapture capture) => !_disposed && !capture.cancelled &&
      identical(_active, capture) && capture.id == _session;
  void _notify() { if (!_disposed) notifyListeners(); }

  Future<void> _initialize() async {
    final previous = _initialization;
    if (previous != null) return previous;
    final task = () async { await _recognizer.initialize(await _prepare()); }();
    _initialization = task;
    try { await task; }
    catch (_) {
      if (identical(_initialization, task)) _initialization = null;
      rethrow;
    }
  }

  Future<T> _recorderCall<T>(_VoiceCapture capture, Future<T> Function() call) {
    final task = call();
    capture.recorderWork = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<T> _engineCall<T>(_VoiceCapture capture, Future<T> Function() call) {
    final task = call();
    capture.engineWork = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<void> start() async {
    if (_disposed || starting || initializing || listening || processing) return;
    if (!supported) {
      error = '离线语音目前支持 Android 和 iOS，也可以输入文字生成账单';
      _notify();
      return;
    }
    final capture = _VoiceCapture(++_session);
    _active = capture;
    starting = true;
    error = null;
    words = '';
    _notify();
    var failure = '无法打开麦克风，请检查录音权限，也可以输入文字继续记账';
    try {
      await _cleanup;
      if (!_current(capture)) return;
      final input = _createInput();
      capture.input = input;
      var granted = await _recorderCall(capture, () => input.hasPermission(request: false));
      if (!_current(capture)) return;
      if (!granted && !_askedPermission) {
        _askedPermission = true;
        granted = await _recorderCall(capture, () => input.hasPermission());
      }
      if (!_current(capture)) return;
      if (!granted) {
        _abort(capture, '请在手机设置里允许麦克风权限，也可以输入文字继续记账');
        return;
      }
      initializing = true;
      failure = '离线语音初始化失败，请重试，也可以输入文字继续记账';
      _notify();
      await _initialize();
      if (!_current(capture)) return;
      initializing = false;
      capture.engineStarted = true;
      await _engineCall(capture, _recognizer.start);
      if (!_current(capture)) return;
      failure = '录音暂不可用，请重试，也可以输入文字继续记账';
      final stream = await _recorderCall(capture, input.startStream);
      if (!_current(capture)) return;
      capture.subscription = stream.listen((chunk) => _accept(capture, chunk),
        onError: (Object _, StackTrace __) => _abort(capture, '录音中断，请重新说一次，也可以输入文字'),
        onDone: () {
          capture.streamClosed = true;
          if (!capture.streamDone.isCompleted) capture.streamDone.complete();
          if (_current(capture) && !capture.stopping) unawaited(stop());
        });
      starting = false;
      listening = true;
      capture.timer = Timer(_recordingLimit, () { if (_current(capture)) unawaited(stop()); });
      _notify();
    } catch (_) {
      if (_current(capture)) _abort(capture, failure);
    } finally {
      if (_current(capture)) { starting = false; initializing = false; _notify(); }
    }
  }

  void _accept(_VoiceCapture capture, Uint8List chunk) {
    if (!_current(capture) || capture.streamClosed || chunk.isEmpty) return;
    // Only 30 seconds of mono PCM can be queued. Neither audio nor recognized
    // words are logged, and startStream never creates a recording file.
    final limit = 16000 * 2 * _recordingLimit.inMilliseconds ~/ 1000;
    final remaining = limit - capture.bytes;
    if (remaining <= 0) { unawaited(stop()); return; }
    final count = chunk.length < remaining ? chunk.length : remaining;
    final bytes = Uint8List.fromList(chunk.sublist(0, count));
    capture.bytes += count;
    capture.pcmWork = capture.pcmWork.then<void>((_) async {
      if (!_current(capture)) return;
      final result = await _engineCall(capture, () => _recognizer.acceptPcm16(bytes));
      if (_current(capture)) {
        final text = result.trim();
        if (words != text) { words = text; _notify(); }
      }
    }).catchError((Object _, StackTrace __) {
      if (_current(capture)) _abort(capture, '离线识别中断，请重新说一次，也可以输入文字');
    });
    if (capture.bytes >= limit) unawaited(stop());
  }

  Future<void> stop() {
    final capture = _active;
    if (capture == null || _disposed) return Future<void>.value();
    if (capture.stopping) return capture.finishing ?? Future<void>.value();
    if (starting || initializing || !listening) return cancel();
    capture.stopping = true;
    capture.timer?.cancel();
    listening = false;
    processing = true;
    _notify();
    final task = _finish(capture);
    capture.finishing = task;
    return task;
  }

  Future<void> _finish(_VoiceCapture capture) async {
    try {
      final input = capture.input;
      if (input == null) return;
      await _recorderCall(capture, input.stop);
      // record 6.2.0 promises full PCM only after the stream close event.
      await capture.streamDone.future.timeout(const Duration(seconds: 3));
      await capture.pcmWork;
      if (!_current(capture)) return;
      final result = await _engineCall(capture, _recognizer.finish);
      if (!_current(capture)) return;
      words = result.trim();
      error = words.isEmpty ? '没有听清，请重新说一次，也可以输入文字' : null;
    } catch (_) {
      if (_current(capture)) _abort(capture, '离线识别暂不可用，请重试，也可以输入文字继续记账');
    } finally {
      await _release(capture);
      if (_current(capture)) {
        _active = null;
        processing = false;
        listening = false;
        starting = false;
        initializing = false;
        _notify();
      }
    }
  }

  void _abort(_VoiceCapture capture, String message) {
    if (!_current(capture)) return;
    _initialization = null;
    error = message;
    unawaited(cancel());
  }

  Future<void> cancel() {
    ++_session;
    final capture = _active;
    _active = null;
    starting = false;
    initializing = false;
    listening = false;
    processing = false;
    if (capture != null) {
      capture.cancelled = true;
      capture.timer?.cancel();
      _cleanup = _cleanup.then<void>((_) => _cancelCapture(capture));
    }
    _notify();
    return _cleanup;
  }

  Future<void> _cancelCapture(_VoiceCapture capture) async {
    await capture.recorderWork;
    try { await capture.input?.cancel(); } catch (_) { /* Best effort native cleanup. */ }
    try { await capture.subscription?.cancel(); } catch (_) { /* Already closed. */ }
    await capture.pcmWork;
    await capture.engineWork;
    if (capture.engineStarted) {
      try { await _recognizer.cancel(); } catch (_) { /* Worker may already be stopped. */ }
    }
    await _release(capture);
  }

  Future<void> _release(_VoiceCapture capture) => capture.release ??= () async {
    capture.timer?.cancel();
    try { await capture.subscription?.cancel(); } catch (_) { /* Already closed. */ }
    try { await capture.input?.dispose(); } catch (_) { /* Already disposed. */ }
  }();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final cleanup = cancel();
    unawaited(() async {
      await cleanup;
      try { await _initialization; } catch (_) { /* Failed initialization. */ }
      try { await _recognizer.dispose(); } catch (_) { /* Best effort worker cleanup. */ }
    }());
    super.dispose();
  }
}
