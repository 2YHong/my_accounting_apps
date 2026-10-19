import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/voice_recognition_service.dart';
import 'package:my_accounting_app/sync/sync_edit_guard.dart';
import 'package:my_accounting_app/widgets/voice_entry_button.dart';

import 'voice_recognition_lifecycle_test.dart'
    show FakeAudio, FakeRecognizer, modelPaths;

class VoiceHarness {
  final audio = FakeAudio();
  final recognizer = FakeRecognizer();
  final recognized = <String>[];
  final typed = <String>[];
  final boundary = GlobalKey();
  late final VoiceRecognitionService voice;
  VoiceHarness({
    Future<Map<String, String>> Function()? prepare,
    Duration recordingLimit = const Duration(seconds: 30),
  }) {
    voice = VoiceRecognitionService.forTesting(
      prepare: prepare ?? () async => modelPaths,
      recognizer: recognizer,
      createInput: () => audio,
      recordingLimit: recordingLimit,
    );
  }
  Widget get app => RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true, fontFamily: 'ProbeChinese'),
      home: Scaffold(
        appBar: AppBar(title: const Text('我的记账本')),
        body: const Center(child: Text('账单')),
        floatingActionButton: VoiceEntryButton(
          service: voice,
          onRecognized: (text) async => recognized.add(text),
          onTypeInstead: (text) async => typed.add(text),
        ),
      ),
    ),
  );
  Future<void> capture(String name) async {
    final folder = Platform.environment['VOICE_UI_SHOTS'];
    if (folder == null) return;
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$folder/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }
}

// Stream cancellation resolves through the real event loop in widget tests.
Future<void> settleRecorder(WidgetTester tester) async {
  // Futures created inside the fake clock can alternate with real stream
  // cancellation futures. Drain both queues before checking released resources.
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final icons = File(
      'D:/Flutter/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(icons.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      final loader = FontLoader('ProbeChinese');
      loader.addFont(() async {
        final data = await font.readAsBytes();
        return ByteData.sublistView(data);
      }());
      await loader.load();
    }
  });

  testWidgets(
    'one tap starts recording and stop reviews the final text directly',
    (tester) async {
      final h = VoiceHarness();
      addTearDown(h.voice.dispose);
      await tester.pumpWidget(h.app);
      await tester.tap(find.byIcon(Icons.mic_rounded));
      await settleRecorder(tester);
      expect(h.audio.starts, 1);
      expect(find.text('正在听'), findsOneWidget);
      expect(find.text('开始说话'), findsNothing);
      h.audio.controller.add(Uint8List.fromList([1, 2]));
      await tester.pump();
      await tester.tap(find.text('说完了，核对账单'));
      await settleRecorder(tester);
      expect(h.recognized, ['今天买牛奶花了七元']);
      expect(h.recognizer.finishes, 1);
      expect(SyncEditGuard.active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hold starts and release finishes exactly once', (tester) async {
    final h = VoiceHarness();
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(h.audio.starts, 1);
    expect(find.text('松开结束，上滑取消'), findsOneWidget);
    await gesture.up();
    await settleRecorder(tester);
    expect(h.recognized, ['今天买牛奶花了七元']);
    expect(h.recognizer.finishes, 1);
    expect(find.text('正在听'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliding up cancels without opening a bill editor', (
    tester,
  ) async {
    final h = VoiceHarness();
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(find.text('松开取消'), findsOneWidget);
    await gesture.up();
    await settleRecorder(tester);
    expect(h.recognized, isEmpty);
    expect(h.audio.cancels, 1);
    expect(h.recognizer.finishes, 0);
    expect(SyncEditGuard.active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('release during startup prevents a late microphone opening', (
    tester,
  ) async {
    final ready = Completer<Map<String, String>>();
    final h = VoiceHarness(prepare: () => ready.future);
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(h.voice.initializing, isTrue);
    await gesture.up();
    await tester.pump();
    ready.complete(modelPaths);
    await settleRecorder(tester);
    expect(h.audio.starts, 0);
    expect(h.recognized, isEmpty);
    expect(SyncEditGuard.active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission denial offers typing and never reuses old words', (
    tester,
  ) async {
    final h = VoiceHarness();
    h.audio.granted = false;
    h.audio.grantRequest = false;
    h.voice.words = '上次录音';
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await settleRecorder(tester);
    expect(h.audio.starts, 0);
    expect(find.text('上次录音'), findsNothing);
    await tester.tap(find.text('改用文字输入'));
    await settleRecorder(tester);
    expect(h.typed, ['']);
    expect(h.recognized, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back cancels an active overlay and releases microphone', (
    tester,
  ) async {
    final h = VoiceHarness();
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await settleRecorder(tester);
    await tester.binding.handlePopRoute();
    await settleRecorder(tester);
    expect(h.recognized, isEmpty);
    expect(h.audio.cancels, 1);
    expect(find.text('正在听'), findsNothing);
    expect(SyncEditGuard.active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposing while preparing leaves no recording or overlay behind',
    (tester) async {
      final ready = Completer<Map<String, String>>();
      final h = VoiceHarness(prepare: () => ready.future);
      addTearDown(h.voice.dispose);
      await tester.pumpWidget(h.app);
      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      ready.complete(modelPaths);
      await settleRecorder(tester);
      expect(h.audio.starts, 0);
      expect(h.recognized, isEmpty);
      expect(SyncEditGuard.active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recording overlay fits a narrow phone and landscape screen', (
    tester,
  ) async {
    final h = VoiceHarness();
    addTearDown(h.voice.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(h.app);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await settleRecorder(tester);
    h.audio.controller.add(Uint8List.fromList([1, 2]));
    await settleRecorder(tester);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => h.capture('voice-tap-phone'));
    await tester.binding.setSurfaceSize(const Size(740, 360));
    await settleRecorder(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await settleRecorder(tester);
  });
  testWidgets('automatic recording limit also opens review exactly once', (
    tester,
  ) async {
    final h = VoiceHarness(recordingLimit: const Duration(seconds: 3));
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await settleRecorder(tester);
    h.audio.controller.add(Uint8List.fromList([1, 2]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await settleRecorder(tester);
    expect(h.recognized, ['今天买牛奶花了七元']);
    expect(h.recognizer.finishes, 1);
    expect(SyncEditGuard.active, isFalse);
  });

  testWidgets('backgrounding cancels recording without creating a bill', (
    tester,
  ) async {
    final h = VoiceHarness();
    addTearDown(h.voice.dispose);
    await tester.pumpWidget(h.app);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await settleRecorder(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settleRecorder(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(h.recognized, isEmpty);
    expect(h.audio.cancels, 1);
    expect(SyncEditGuard.active, isFalse);
  });
}
