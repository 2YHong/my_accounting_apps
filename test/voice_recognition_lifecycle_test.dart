import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/voice_recognition_service.dart';

const modelPaths = {'encoder': 'encoder', 'decoder': 'decoder', 'joiner': 'joiner', 'tokens': 'tokens'};
Future<void> flush() => Future<void>.delayed(Duration.zero);

class FakeAudio implements VoiceAudioInput {
  final controller = StreamController<Uint8List>.broadcast();
  bool granted = true;
  bool grantRequest = true;
  Uint8List? finalChunk;
  int starts = 0;
  int stops = 0;
  int cancels = 0;
  int disposals = 0;
  final permissionRequests = <bool>[];
  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionRequests.add(request);
    if (request) granted = grantRequest;
    return granted;
  }
  @override
  Future<Stream<Uint8List>> startStream() async { starts++; return controller.stream; }
  @override
  Future<void> stop() async {
    stops++;
    if (!controller.isClosed) {
      if (finalChunk != null) controller.add(finalChunk!);
      await controller.close();
    }
  }
  @override
  Future<void> cancel() async {
    cancels++;
    if (!controller.isClosed) await controller.close();
  }
  @override
  Future<void> dispose() async {
    disposals++;
    if (!controller.isClosed) await controller.close();
  }
}

class FakeRecognizer implements VoiceOfflineRecognizer {
  int initializations = 0;
  int starts = 0;
  int finishes = 0;
  int cancels = 0;
  int disposals = 0;
  Completer<void>? nextChunkGate;
  Completer<void>? startGate;
  final chunks = <List<int>>[];
  @override
  Future<void> initialize(Map<String, String> paths) async { initializations++; }
  @override
  Future<void> start() async { starts++; if (startGate != null) await startGate!.future; }
  @override
  Future<String> acceptPcm16(Uint8List bytes) async {
    final gate = nextChunkGate;
    nextChunkGate = null;
    if (gate != null) await gate.future;
    chunks.add(bytes.toList());
    return '牛奶';
  }
  @override
  Future<String> finish() async { finishes++; return '今天买牛奶花了七元'; }
  @override
  Future<void> cancel() async { cancels++; }
  @override
  Future<void> dispose() async { disposals++; }
}

void main() {
  test('Cancel while preparing models never opens an obsolete microphone', () async {
    final prepared = Completer<Map<String, String>>();
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(prepare: () => prepared.future,
      recognizer: recognizer, createInput: () => audio);
    final starting = voice.start();
    await flush();
    expect(voice.initializing, isTrue);
    await voice.cancel();
    prepared.complete(modelPaths);
    await starting;
    expect(audio.starts, 0);
    expect(audio.disposals, 1);
    expect(recognizer.starts, 0);
    expect(voice.listening, isFalse);
    voice.dispose();
  });

  test('Stop during initialization cancels instead of starting recording later', () async {
    final prepared = Completer<Map<String, String>>();
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(prepare: () => prepared.future,
      recognizer: recognizer, createInput: () => audio);
    final starting = voice.start();
    await flush();
    await voice.stop();
    prepared.complete(modelPaths);
    await starting;
    expect(audio.starts, 0);
    expect(recognizer.finishes, 0);
    voice.dispose();
  });

  test('Rapid cancel and restart use one model initialization and a fresh recorder', () async {
    final prepared = Completer<Map<String, String>>();
    final inputs = <FakeAudio>[];
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(prepare: () => prepared.future,
      recognizer: recognizer, createInput: () { final input = FakeAudio(); inputs.add(input); return input; });
    final oldStart = voice.start();
    await flush();
    await voice.cancel();
    final newStart = voice.start();
    await flush();
    prepared.complete(modelPaths);
    await Future.wait([oldStart, newStart]);
    expect(inputs, hasLength(2));
    expect(inputs.first.starts, 0);
    expect(inputs.last.starts, 1);
    expect(recognizer.initializations, 1);
    expect(recognizer.starts, 1);
    expect(voice.listening, isTrue);
    await voice.cancel();
    voice.dispose();
  });

  test('Cancellation during recognizer setup cannot open the microphone afterward', () async {
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final gate = Completer<void>();
    recognizer.startGate = gate;
    final voice = VoiceRecognitionService.forTesting(prepare: () async => modelPaths,
      recognizer: recognizer, createInput: () => audio);
    final starting = voice.start();
    await flush();
    expect(recognizer.starts, 1);
    final cancelling = voice.cancel();
    gate.complete();
    await Future.wait([starting, cancelling]);
    expect(audio.starts, 0);
    expect(recognizer.cancels, 1);
    expect(audio.disposals, 1);
    voice.dispose();
  });

  test('Stop drains the last PCM chunk and awaits recognition before publishing final text', () async {
    final audio = FakeAudio()..finalChunk = Uint8List.fromList([3, 4]);
    final recognizer = FakeRecognizer();
    final gate = Completer<void>();
    recognizer.nextChunkGate = gate;
    final voice = VoiceRecognitionService.forTesting(prepare: () async => modelPaths,
      recognizer: recognizer, createInput: () => audio);
    await voice.start();
    audio.controller.add(Uint8List.fromList([1, 2]));
    await flush();
    final stopping = voice.stop();
    await flush();
    expect(voice.processing, isTrue);
    expect(recognizer.finishes, 0);
    gate.complete();
    await stopping;
    expect(recognizer.chunks, [[1, 2], [3, 4]]);
    expect(recognizer.finishes, 1);
    expect(voice.words, '今天买牛奶花了七元');
    expect(voice.processing, isFalse);
    expect(audio.disposals, 1);
    voice.dispose();
  });

  test('Cancellation suppresses text from a chunk already being recognized', () async {
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final gate = Completer<void>();
    recognizer.nextChunkGate = gate;
    final voice = VoiceRecognitionService.forTesting(prepare: () async => modelPaths,
      recognizer: recognizer, createInput: () => audio);
    await voice.start();
    audio.controller.add(Uint8List.fromList([1, 2]));
    await flush();
    final cancelling = voice.cancel();
    expect(voice.listening, isFalse);
    gate.complete();
    await cancelling;
    expect(voice.words, isEmpty);
    expect(recognizer.cancels, 1);
    expect(recognizer.finishes, 0);
    expect(audio.disposals, 1);
    voice.dispose();
  });

  test('Repeated stop and start taps cannot overlap a final recognition', () async {
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final gate = Completer<void>();
    recognizer.nextChunkGate = gate;
    final voice = VoiceRecognitionService.forTesting(prepare: () async => modelPaths,
      recognizer: recognizer, createInput: () => audio);
    await voice.start();
    audio.controller.add(Uint8List.fromList([1, 2]));
    await flush();
    final firstStop = voice.stop();
    final secondStop = voice.stop();
    expect(identical(firstStop, secondStop), isTrue);
    await voice.start();
    expect(recognizer.starts, 1);
    gate.complete();
    await firstStop;
    expect(audio.stops, 1);
    expect(recognizer.finishes, 1);
    voice.dispose();
  });

  test('A denied microphone permission is requested once then offers text entry', () async {
    final inputs = <FakeAudio>[];
    final recognizer = FakeRecognizer();
    var preparations = 0;
    final voice = VoiceRecognitionService.forTesting(prepare: () async { preparations++; return modelPaths; },
      recognizer: recognizer, createInput: () {
        final input = FakeAudio()..granted = false ..grantRequest = false;
        inputs.add(input); return input;
      });
    await voice.start();
    await voice.cancel();
    await voice.start();
    await voice.cancel();
    expect(inputs.first.permissionRequests, [false, true]);
    expect(inputs.last.permissionRequests, [false]);
    expect(preparations, 0);
    expect(voice.error, contains('麦克风权限'));
    expect(voice.listening, isFalse);
    voice.dispose();
  });

  test('Unsupported platforms do not create recorder or model resources', () async {
    var inputs = 0;
    var preparations = 0;
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(supported: false,
      prepare: () async { preparations++; return modelPaths; }, recognizer: recognizer,
      createInput: () { inputs++; return FakeAudio(); });
    await voice.start();
    expect(inputs, 0);
    expect(preparations, 0);
    expect(voice.error, contains('Android'));
    voice.dispose();
  });

  test('Model preparation failure is private and retry does not reuse the failed future', () async {
    var preparations = 0;
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(prepare: () async {
      if (++preparations == 1) throw StateError('private internal diagnostic');
      return modelPaths;
    }, recognizer: recognizer, createInput: FakeAudio.new);
    await voice.start();
    await voice.cancel();
    expect(voice.error, isNot(contains('private')));
    expect(voice.listening, isFalse);
    await voice.start();
    expect(preparations, 2);
    expect(recognizer.initializations, 1);
    expect(voice.listening, isTrue);
    expect(voice.error, isNull);
    await voice.cancel();
    voice.dispose();
  });

  test('The recording time limit stops capture and delivers its final recognition', () async {
    final audio = FakeAudio();
    final recognizer = FakeRecognizer();
    final voice = VoiceRecognitionService.forTesting(prepare: () async => modelPaths,
      recognizer: recognizer, createInput: () => audio,
      recordingLimit: const Duration(milliseconds: 20));
    await voice.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(audio.stops, 1);
    expect(voice.listening, isFalse);
    expect(voice.processing, isFalse);
    expect(recognizer.finishes, 1);
    expect(voice.words, '今天买牛奶花了七元');
    voice.dispose();
  });
}
