import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class OfflineSpeechException implements Exception {
  final String message;
  const OfflineSpeechException(this.message);
  @override
  String toString() => message;
}

/// Converts arbitrary recorder chunks without discarding a sample split across
/// two chunks. The source is signed 16-bit little-endian, mono, at 16 kHz.
class Pcm16LeDecoder {
  int? _lowByte;
  Float32List convert(Uint8List bytes) {
    final samples = Float32List((bytes.length + (_lowByte == null ? 0 : 1)) ~/ 2);
    var input = 0;
    var output = 0;
    if (_lowByte != null && bytes.isNotEmpty) {
      samples[output++] = _sample(_lowByte!, bytes[input++]);
      _lowByte = null;
    }
    while (input + 1 < bytes.length) {
      samples[output++] = _sample(bytes[input], bytes[input + 1]);
      input += 2;
    }
    if (input < bytes.length) _lowByte = bytes[input];
    return samples;
  }
  static double _sample(int low, int high) {
    final unsigned = low | (high << 8);
    return (unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned) / 32768.0;
  }
  void reset() { _lowByte = null; }
}

/// Join Chinese token spacing while retaining spacing inside English names.
String normalizeOfflineChineseText(String text) {
  var result = text.trim();
  final pattern = RegExp(r'([\u3400-\u9fff0-9])\s+(?=[\u3400-\u9fff0-9])');
  result = result.replaceAllMapped(pattern, (match) => match[1]!);
  result = result.replaceAllMapped(RegExp(r'([0-9])\s*([.．])\s*(?=[0-9])'),
    (match) => '${match[1]}.');
  return result;
}

/// Native model creation and all inference run in a persistent isolate. This
/// object transports PCM in memory; it never records or uploads audio files.
class OfflineChineseRecognizer {
  Isolate? _worker;
  ReceivePort? _responses;
  StreamSubscription<dynamic>? _responseSubscription;
  SendPort? _commands;
  final _pending = <int, Completer<Object?>>{};
  Completer<void>? _connected;
  Future<void>? _initializing;
  int _nextId = 0;
  bool _ready = false;
  bool _disposed = false;

  Future<void> initialize(Map<String, String> paths) {
    if (_disposed) return Future.error(const OfflineSpeechException('语音识别已关闭'));
    if (_ready) return Future.value();
    return _initializing ??= _initialize(paths).whenComplete(() => _initializing = null);
  }

  Future<void> _initialize(Map<String, String> paths) async {
    if (!['encoder','decoder','joiner','tokens'].every((key) => paths[key]?.isNotEmpty == true)) {
      throw const OfflineSpeechException('中文语音模型不完整，请重新打开软件');
    }
    try {
      await _closeWorker();
      _responses = ReceivePort();
      _connected = Completer<void>();
      _responseSubscription = _responses!.listen(_onMessage);
      _worker = await Isolate.spawn(_recognizerWorker, _responses!.sendPort,
        onError: _responses!.sendPort, onExit: _responses!.sendPort,
        errorsAreFatal: true, debugName: 'offline_chinese_voice');
      await _connected!.future.timeout(const Duration(seconds: 30));
      await _request('initialize', Map<String,String>.from(paths), timeoutSeconds: 60);
      _ready = true;
    } catch (_) {
      await _closeWorker();
      throw const OfflineSpeechException('离线中文语音初始化失败，请关闭语音页面后重试');
    }
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      _commands = message;
      if (_connected?.isCompleted == false) _connected!.complete();
      return;
    }
    if (message is Map && message['id'] is int) {
      final completer = _pending.remove(message['id']);
      if (completer == null || completer.isCompleted) return;
      if (message['ok'] == true) {
        completer.complete(message['value']);
      } else {
        completer.completeError(const OfflineSpeechException('中文语音识别失败，请重新录音'));
      }
      return;
    }
    // Exit and uncaught native-worker errors deliberately expose no internal
    // paths, audio, recognized words or exception details to the application.
    _ready = false;
    _commands = null;
    final error = const OfflineSpeechException('中文语音识别已停止，请重新打开语音页面');
    if (_connected?.isCompleted == false) _connected!.completeError(error);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Object?> _request(String operation, Object? payload, {int timeoutSeconds = 30}) async {
    final port = _commands;
    if (port == null) throw const OfflineSpeechException('中文语音识别尚未就绪');
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send({'id': id, 'operation': operation, 'payload': payload});
    try {
      return await completer.future.timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      await _closeWorker();
      throw const OfflineSpeechException('中文语音识别超时，请重新打开语音页面');
    } finally { _pending.remove(id); }
  }

  void _checkReady() {
    if (_disposed || !_ready) throw const OfflineSpeechException('中文语音识别尚未就绪');
  }
  Future<void> start() async { _checkReady(); await _request('start', null); }
  Future<String> acceptPcm16(Uint8List bytes) async {
    _checkReady();
    if (bytes.length > 1024 * 1024) throw const OfflineSpeechException('录音数据块过大，请重新录音');
    return await _request('accept', Uint8List.fromList(bytes)) as String;
  }
  Future<String> finish() async { _checkReady(); return await _request('finish', null) as String; }
  Future<void> cancel() async {
    if (_disposed || !_ready) return;
    await _request('cancel', null);
  }
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _initializing;
      if (_commands != null) await _request('dispose', null, timeoutSeconds: 5);
    } catch (_) { /* Always close local ports, even after a worker failure. */ }
    finally { await _closeWorker(); }
  }
  Future<void> _closeWorker() async {
    _ready = false;
    _commands = null;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    await _responseSubscription?.cancel();
    _responseSubscription = null;
    _responses?.close();
    _responses = null;
    final error = const OfflineSpeechException('中文语音识别已关闭');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

void _recognizerWorker(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  final pcm = Pcm16LeDecoder();
  var sampleCount = 0;
  void freeStream() { stream?.free(); stream = null; pcm.reset(); sampleCount = 0; }
  String decodeAll() {
    final current = stream;
    final model = recognizer;
    if (current == null || model == null) throw const OfflineSpeechException('没有正在识别的录音');
    while (model.isReady(current)) { model.decode(current); }
    return normalizeOfflineChineseText(model.getResult(current).text);
  }
  commands.listen((dynamic message) {
    if (message is! Map || message['id'] is! int) return;
    final id = message['id'] as int;
    final operation = message['operation'];
    try {
      Object? value;
      switch (operation) {
        case 'initialize':
          final paths = Map<String,String>.from(message['payload'] as Map);
          freeStream(); recognizer?.free(); recognizer = null;
          sherpa.initBindings();
          recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
            feat: const sherpa.FeatureConfig(sampleRate:16000,featureDim:80),
            model: sherpa.OnlineModelConfig(
              transducer: sherpa.OnlineTransducerModelConfig(encoder:paths['encoder']!,
                decoder:paths['decoder']!,joiner:paths['joiner']!),
              tokens:paths['tokens']!,numThreads:2,provider:'cpu',debug:false,modelType:'zipformer'),
            enableEndpoint:false));
          break;
        case 'start':
          freeStream();
          if (recognizer == null) throw const OfflineSpeechException('模型尚未初始化');
          stream = recognizer!.createStream();
          break;
        case 'accept':
          if (stream == null) throw const OfflineSpeechException('没有正在识别的录音');
          final samples = pcm.convert(message['payload'] as Uint8List);
          sampleCount += samples.length;
          if (sampleCount > 16000 * 65) throw const OfflineSpeechException('录音时间过长');
          if (samples.isNotEmpty) stream!.acceptWaveform(samples:samples,sampleRate:16000);
          value = decodeAll();
          break;
        case 'finish':
          if (stream == null) throw const OfflineSpeechException('没有正在识别的录音');
          try {
            if (sampleCount == 0) { value = ''; }
            else {
              stream!.acceptWaveform(samples:Float32List(12800),sampleRate:16000);
              stream!.inputFinished();
              value = decodeAll();
            }
          } finally { freeStream(); }
          break;
        case 'cancel':
          freeStream();
          break;
        case 'dispose':
          freeStream(); recognizer?.free(); recognizer = null;
          replies.send({'id':id,'ok':true,'value':null});
          commands.close();
          return;
        default: throw const OfflineSpeechException('不支持的语音操作');
      }
      replies.send({'id':id,'ok':true,'value':value});
    } catch (_) {
      // Free a failed utterance so a subsequent start cannot consume old audio.
      try { freeStream(); } catch (_) { stream = null; pcm.reset(); sampleCount = 0; }
      replies.send({'id':id,'ok':false});
    }
  });
}
