import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/screenshot_bill_parser.dart';

void main() {
  final now = DateTime(2026, 10, 19);
  test(
    'WeChat detail uses real payment, not balance, discount, time or order ID',
    () {
      final d = ScreenshotBillParser.parse(
        '微信支付\n支付成功\n-50.00\n商家\n楼下便利店\n实付金额\n¥50.00\n优惠 ¥5.00\n账户余额 ¥450.00\n支付时间 2026-10-18 12:34:56\n交易单号 420000123456789012',
        now: now,
      );
      expect(d.amountCents, 5000);
      expect(d.type, 'expense');
      expect(d.title, '楼下便利店');
      expect(d.date, DateTime(2026, 10, 18));
    },
  );
  test('Alipay incoming money remains income', () {
    final d = ScreenshotBillParser.parse(
      '账单详情\n转账收入\n+1,500.50\n交易对方：测试公司\n交易时间 2026/10/17 11:20',
      now: now,
    );
    expect(d.type, 'income');
    expect(d.amountCents, 150050);
    expect(d.title, '测试公司');
  });
  test('English screenshot parses Chinese model Latin output', () {
    final d = ScreenshotBillParser.parse(
      'Payment successful\nMerchant: Coffee Shop\nAmount: CNY 25.90\nBalance CNY 100.00\n2026-10-16 09:00',
      now: now,
    );
    expect(d.amountCents, 2590);
    expect(d.title, 'Coffee Shop');
    expect(d.date, DateTime(2026, 10, 16));
  });
  test('multiple same priority amounts stay blank for review', () {
    final d = ScreenshotBillParser.parse(
      '账单列表\n¥20.00\n¥30.00\n订单号 1234567890',
      now: now,
    );
    expect(d.amountCents, isNull);
    expect(d.hints.any((s) => s.contains('金额不明确')), isTrue);
  });
  test('phone numbers, IDs and invalid dates cannot become money or date', () {
    final d = ScreenshotBillParser.parse(
      '交易单号\n202610190001\n手机号 13800138000\n2026-02-31 10:00',
      now: now,
    );
    expect(d.amountCents, isNull);
    expect(d.date, now);
  });
  test('duplicate displayed totals yield one amount; zero is not a bill', () {
    expect(
      ScreenshotBillParser.parse('金额 ¥25.00\n实付 ¥25.00', now: now).amountCents,
      2500,
    );
    expect(
      ScreenshotBillParser.parse('支付金额 0.00', now: now).amountCents,
      isNull,
    );
  });
}
