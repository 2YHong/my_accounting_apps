import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/recurring_bill.dart';

void main() {
  RecurringBill rule({int day = 31, DateTime? start, DateTime? active,
    bool enabled = true, DateTime? deletedAt}) => RecurringBill(
      id: 1, userId: 1, title: '月租', type: 'expense', amountCents: 700,
      ledgerId: 1, categoryId: 1, dayOfMonth: day,
      startDate: start ?? DateTime(2026, 1, 1),
      activeFrom: active ?? DateTime(2026, 1, 1), enabled: enabled, deletedAt: deletedAt);

  test('31号在二月和四月按月末，闰年保留29日', () {
    expect(RecurringBill.dueDate(2026, 2, 31), DateTime(2026, 2, 28));
    expect(RecurringBill.dueDate(2028, 2, 31), DateTime(2028, 2, 29));
    expect(RecurringBill.dueDate(2026, 4, 31), DateTime(2026, 4, 30));
    expect(RecurringBill.dueDate(2026, 12, 31), DateTime(2026, 12, 31));
  });

  test('跨年积压月份按期排列，不只返回本月', () {
    final dates = rule(start: DateTime(2025, 11, 1), active: DateTime(2025, 11, 1))
      .datesBetween(DateTime(2025, 11, 1), DateTime(2026, 2, 28)).toList();
    expect(dates, [DateTime(2025, 11, 30), DateTime(2025, 12, 31),
      DateTime(2026, 1, 31), DateTime(2026, 2, 28)]);
  });

  test('新计划和重新启用不会回溯启用前的月份', () {
    final dates = rule(day: 10, active: DateTime(2026, 10, 13))
      .datesBetween(DateTime(2026, 1, 1), DateTime(2026, 12, 31)).toList();
    expect(dates, [DateTime(2026, 11, 10), DateTime(2026, 12, 10)]);
  });

  test('开始日期有未来限制，日期当天包含到期项目', () {
    expect(rule(day: 10, start: DateTime(2026, 12, 10))
      .datesBetween(DateTime(2026, 10, 1), DateTime(2026, 12, 10)).toList(), [DateTime(2026, 12, 10)]);
    expect(rule(day: 10).datesBetween(DateTime(2026, 1, 11), DateTime(2026, 1, 31)), isEmpty);
  });

  test('重复读取排除已确认和跳过期，删除账单也无需重生成', () {
    final dates = rule(day: 15).datesBetween(DateTime(2026, 1, 1), DateTime(2026, 3, 31),
      excludedPeriods: {'2026-01', '2026-03'}).toList();
    expect(dates, [DateTime(2026, 2, 15)]);
    expect(RecurringBill.periodFor(DateTime(2026, 2, 15)), '2026-02');
  });

  test('暂停或删除计划不产生新到期项目', () {
    expect(rule(enabled: false).datesBetween(DateTime(2026), DateTime(2027)), isEmpty);
    expect(rule(deletedAt: DateTime(2026, 5, 1)).datesBetween(DateTime(2026), DateTime(2027)), isEmpty);
  });

  test('金额按分解析，不累计浮点误差且拒绝无效输入', () {
    expect(RecurringBill.parseAmountCents('7'), 700);
    expect(RecurringBill.parseAmountCents('7.05'), 705);
    expect(RecurringBill.parseAmountCents(' 0.10 '), 10);
    for (final text in ['0', '-7', '7.001', 'NaN', 'Infinity', '7e2', 'abc']) {
      expect(RecurringBill.parseAmountCents(text), isNull);
    }
    expect(rule().amountText, '7.00');
  });

  test('无效的每月日期不能静默转换', () {
    expect(() => RecurringBill.dueDate(2026, 1, 0), throwsArgumentError);
    expect(() => RecurringBill.dueDate(2026, 1, 32), throwsArgumentError);
  });

  test('单期快照保存完整计划，金额大时仍可按分还原', () {
    final original = rule(day: 29, active: DateTime(2026, 10, 13));
    final restored = RecurringBill.fromMap(original.toMap());
    expect(restored.dayOfMonth, 29);
    expect(restored.activeFrom, DateTime(2026, 10, 13));
    expect(restored.amountCents, 700);
    expect(restored.ledgerId, 1);
    for (final cents in [10, 705, 99999999999, 999999999999]) {
      expect(RecurringBill.parseAmountCents((cents / 100).toStringAsFixed(2)), cents);
    }
  });
}
