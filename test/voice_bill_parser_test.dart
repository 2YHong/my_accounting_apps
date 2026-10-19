import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/voice_bill_parser.dart';

void main() {
  final now = DateTime(2026, 10, 13, 15);
  test('milk example separates quantity from amount and extracts product', () {
    final draft = VoiceBillParser.parse('今天我买了两包牛奶，花了七元。', now: now);
    expect(draft.type, 'expense');
    expect(draft.amountCents, 700);
    expect(draft.title, '牛奶');
    expect(draft.date, DateTime(2026, 10, 13));
  });
  test('income and Chinese decimal amount', () {
    final draft = VoiceBillParser.parse('昨天收到工资五千二百元', now: now);
    expect(draft.type, 'income');
    expect(draft.amountCents, 520000);
    expect(draft.title, '工资');
    expect(draft.date, DateTime(2026, 10, 12));
    expect(VoiceBillParser.parse('买了公交票花了三点五元').amountCents, 350);
  });
  test('multiple amounts require manual choice', () {
    expect(VoiceBillParser.parse('牛奶七元，面包五元').amountCents, isNull);
    expect(VoiceBillParser.parse('七元，五元').amountCents, isNull);
  });
  test('quantities alone cannot become money', () {
    expect(VoiceBillParser.parse('今天买了两包牛奶').amountCents, isNull);
  });
  test('currency fractions and spoken shorthand', () {
    expect(VoiceBillParser.parse('牛奶七元五角二分').amountCents, 752);
    expect(VoiceBillParser.parse('牛奶七块五').amountCents, 750);
    expect(VoiceBillParser.parse('牛奶7.25元').amountCents, 725);
  });
  test('invalid dates and cancelled spending are not accepted silently', () {
    expect(VoiceBillParser.parse('2月30日牛奶七元', now: now).hints, isNotEmpty);
    expect(VoiceBillParser.parse('没有买牛奶，没有花七元').amountCents, isNull);
  });
  test('negative amounts and excess decimal places stay blank', () {
    expect(VoiceBillParser.parse('花了-7元').amountCents, isNull);
    expect(VoiceBillParser.parse('花了12.345元').amountCents, isNull);
    expect(VoiceBillParser.parse('花了七点零零五元').amountCents, isNull);
    expect(VoiceBillParser.parse('花了12.345').amountCents, isNull);
    expect(VoiceBillParser.parse('工资5,200元').amountCents, isNull);
    expect(VoiceBillParser.parse('花了1.2.3元').amountCents, isNull);
  });
  test('last year is retained when combined with a month and day', () {
    expect(VoiceBillParser.parse('去年10月1日买了牛奶七元', now: now).date,
      DateTime(2025, 10, 1));
  });
}
