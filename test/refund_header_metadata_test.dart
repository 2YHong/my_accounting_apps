import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';

void main() {
  test('Cumulative refund semantics and export timestamp survive canonicalization', () {
    const csv = '支付宝交易明细\n导出时间：2026-10-14 09:15:00\n'
      '交易时间,收/支,金额(元),成功退款(元),交易订单号,交易状态\n'
      '2026-10-01 12:00:00,支出,100.00,30.00,ORDER1,交易成功\n';
    final table = BillFileReader.read('支付宝.csv', utf8.encode(csv)).single;
    expect(table.headers[3], '退款金额');
    expect(table.originalHeaders[3], '成功退款(元)');
    expect(table.exportedAt, DateTime(2026, 10, 14, 9, 15));
    expect(table.rows.single[3], '30.00');
  });
  test('Generic refund amount never acquires cumulative-success semantics', () {
    const csv = '微信支付账单\n'
      '交易时间,收/支,金额(元),退款金额(元),交易单号,原交易单号,退款单号,退款成功时间\n'
      '2026-10-14 09:00:00,不计收支,30,30,R1,P1,R1,2026-10-14 09:00:00\n';
    final table = BillFileReader.read('微信.csv', utf8.encode(csv)).single;
    expect(table.originalHeaders[3], '退款金额(元)');
    expect(table.headers, containsAll(['原交易号', '退款号', '退款时间']));
    expect(table.exportedAt, isNull);
  });
  test('Conflicting or invalid export dates are not trusted snapshot timestamps', () {
    const header = '交易时间,收/支,金额,成功退款,交易订单号\n'
      '2026-10-01,支出,100,30,P1\n';
    final conflict = BillFileReader.read('支付宝.csv', utf8.encode(
      '导出时间：2026-10-14 09:00:00\n导出时间：2026-10-15 09:00:00\n$header')).single;
    final invalid = BillFileReader.read('支付宝.csv', utf8.encode(
      '导出时间：2026-02-30 09:00:00\n$header')).single;
    expect(conflict.exportedAt, isNull);
    expect(invalid.exportedAt, isNull);
  });
  test('Explicit platform refund-only tables can preserve order linkage', () {
    const csv = '微信支付退款明细\n'
      '原交易单号,退款单号,退款金额(元),退款成功时间,退款状态\n'
      'P1,R1,30.00,2026-10-14 09:00:00,退款成功\n';
    final table = BillFileReader.read('微信退款.csv', utf8.encode(csv)).single;
    expect(table.source, '微信');
    expect(table.headers, ['原交易号', '退款号', '退款金额', '退款时间', '退款状态']);
    expect(table.rows.single.first, 'P1');
  });
}
