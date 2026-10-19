import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/pages/month_picker_dialog.dart';

// This tests the actual month selector without starting the native SQLite,
// microphone, or notification plugins used by the full mobile application.
Widget _monthPickerHost(DateTime selected, ValueChanged<DateTime?> onSelected) {
  return MaterialApp(key: UniqueKey(), home: Scaffold(body: Builder(builder: (context) => Center(
    child: FilledButton(onPressed: () async {
      final result = await showDialog<DateTime>(context: context,
        builder: (_) => MonthPickerDialog(selected: selected));
      onSelected(result);
    }, child: const Text('打开月份选择'))))));
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('打开月份选择'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('窄屏上10到12月均能正确选择，布局没有异常', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final month in [10, 11, 12]) {
      DateTime? result;
      await tester.pumpWidget(_monthPickerHost(DateTime(2026, 10), (value) => result = value));
      await _openPicker(tester);
      expect(tester.takeException(), isNull);
      final button = find.widgetWithText(OutlinedButton, '$month月');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(result, DateTime(2026, month));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('左右切年后返回所选年月', (tester) async {
    DateTime? result;
    await tester.pumpWidget(_monthPickerHost(DateTime(2026, 10), (value) => result = value));
    await _openPicker(tester);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();
    expect(find.text('2025年'), findsOneWidget);
    await tester.tap(find.byTooltip('下一年'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一年'));
    await tester.pumpAndSettle();
    expect(find.text('2027年'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '1月'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2027, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('直接输入年份，拒绝范围外年份并接受有效年份', (tester) async {
    DateTime? result;
    await tester.pumpWidget(_monthPickerHost(DateTime(2026, 10), (value) => result = value));
    await _openPicker(tester);
    await tester.tap(find.text('2026年'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2201');
    await tester.tap(find.byTooltip('使用此年份'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1900 至 2200 年'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(find.byType(TextField), '2024');
    await tester.pump();
    await tester.tap(find.byTooltip('使用此年份'));
    await tester.pumpAndSettle();
    expect(find.text('2024年'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '2月'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2024, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('年份边界不会切换到支持范围之外', (tester) async {
    for (final year in [1900, 2200]) {
      DateTime? result;
      await tester.pumpWidget(_monthPickerHost(DateTime(year, 1), (value) => result = value));
      await _openPicker(tester);
      final tooltip = year == 1900 ? '上一年' : '下一年';
      final arrow = find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton));
      expect(tester.widget<IconButton>(arrow).onPressed, isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, '1月'));
      await tester.pumpAndSettle();
      expect(result, DateTime(year, 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('回到本月使用当前年月', (tester) async {
    DateTime? result;
    await tester.pumpWidget(_monthPickerHost(DateTime(2000, 1), (value) => result = value));
    await _openPicker(tester);
    final before = DateTime.now();
    await tester.ensureVisible(find.text('回到本月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回到本月'));
    await tester.pumpAndSettle();
    final after = DateTime.now();
    expect(result, isIn([DateTime(before.year, before.month), DateTime(after.year, after.month)]));
    expect(tester.takeException(), isNull);
  });
}
