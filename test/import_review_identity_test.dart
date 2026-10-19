import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/models/import_review.dart';
import 'package:my_accounting_app/services/import_review_service.dart';

ImportReviewItem reviewItem(Map<String, String> original, {String? candidateKey}) {
  final candidate = candidateKey == null ? null : ExpenseRecord(
    ledgerId: 1,
    categoryId: 1,
    type: 'expense',
    amount: 10,
    date: DateTime(2026, 10, 14),
    importKey: candidateKey,
  );
  return ImportReviewItem.fromMap({
    'id': 1,
    'source': '微信',
    'reason': '退款需要核对',
    'payload': jsonEncode({'original': original, 'candidate': candidate?.toMap()}),
  });
}

void main() {
  test('Independent refunds use original-payment aliases before candidate identity', () {
    for (final alias in ['原交易号', '原交易单号', '原交易订单号', '原微信支付订单号']) {
      final item = reviewItem({
        alias: '\uFEFF PAYMENT001\t',
        '交易单号': 'REFUND001',
        '退款单号': 'REFUND001',
      }, candidateKey: '微信:REFUND001');
      expect(ImportReviewService.importKeyFor(item), '微信:PAYMENT001', reason: alias);
    }
  });

  test('Refund ID without an original-payment ID cannot create a bill identity', () {
    final item = reviewItem({
      '退款单号': 'REFUND001',
      '交易单号': 'REFUND001',
    }, candidateKey: '微信:REFUND001');
    expect(ImportReviewService.importKeyFor(item), isNull);
  });

  test('Scientific-notation original IDs do not fall back to the refund candidate', () {
    final item = reviewItem({
      '原微信支付订单号': '1.2345E+22\t',
      '退款单号': 'REFUND001',
    }, candidateKey: '微信:REFUND001');
    expect(ImportReviewService.importKeyFor(item), isNull);
  });

  test('Conflicting original-payment aliases cannot select either payment', () {
    final item = reviewItem({
      '原交易号': 'PAYMENT001',
      '原交易单号': 'PAYMENT002',
      '退款单号': 'REFUND001',
    }, candidateKey: '微信:REFUND001');
    expect(ImportReviewService.importKeyFor(item), isNull);
  });

  test('A normal payment retains its parsed candidate identity', () {
    final item = reviewItem({
      '交易单号': 'PAYMENT001',
      '收/支': '支出',
    }, candidateKey: '微信:PAYMENT001');
    expect(ImportReviewService.importKeyFor(item), '微信:PAYMENT001');
  });
}
