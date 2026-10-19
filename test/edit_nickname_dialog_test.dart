import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/widgets/edit_nickname_dialog.dart';

Widget host(Future<void> Function(String) save, ValueChanged<String?> done) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              done(
                await showDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) =>
                      EditNicknameDialog(initialName: '默认用户', onSave: save),
                ),
              );
            },
            child: const Text('编辑'),
          ),
        ),
      ),
    );

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('save waits for persistence and prevents duplicate submits', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    String? result;
    String? saved;
    await tester.pumpWidget(
      host((name) {
        calls++;
        saved = name;
        return pending.future;
      }, (value) => result = value),
    );
    await open(tester);
    await tester.enterText(find.byType(TextField), '  小明  ');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(calls, 1);
    expect(saved, '小明');
    expect(result, isNull);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(result, '小明');
    expect(find.byType(EditNicknameDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('write failure keeps the editor open and permits retry', (
    tester,
  ) async {
    var stored = '默认用户';
    var fail = true;
    String? result;
    await tester.pumpWidget(
      host((name) async {
        if (fail) throw StateError('simulated database write failure');
        stored = name;
      }, (value) => result = value),
    );
    await open(tester);
    await tester.enterText(find.byType(TextField), '新的昵称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(stored, '默认用户');
    expect(result, isNull);
    expect(find.text('昵称保存失败，请重试'), findsOneWidget);
    expect(find.byType(EditNicknameDialog), findsOneWidget);
    fail = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, '新的昵称');
    expect(stored, '新的昵称');
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank nickname and cancellation never write user data', (
    tester,
  ) async {
    var calls = 0;
    String? result;
    await tester.pumpWidget(
      host((_) async => calls++, (value) => result = value),
    );
    await open(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入昵称'), findsOneWidget);
    expect(calls, 0);
    await tester.enterText(find.byType(TextField), '不保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard save supports emoji nickname and safe disposal', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(host((_) async {}, (value) => result = value));
    await open(tester);
    await tester.enterText(find.byType(TextField), '🌻记账');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, '🌻记账');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
