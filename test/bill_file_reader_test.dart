import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/models/import_review.dart';
import 'package:my_accounting_app/services/bill_csv_service.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';
import 'package:my_accounting_app/services/import_review_service.dart';

List<int> utf16Bytes(String text, {bool littleEndian = true, bool bom = true}) {
  final bytes = <int>[
    if (bom) ...(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]),
  ];
  for (final unit in text.codeUnits) {
    bytes.addAll(littleEndian
        ? [unit & 0xFF, unit >> 8]
        : [unit >> 8, unit & 0xFF]);
  }
  return bytes;
}

const wechatHeader = '交易时间,交易类型,交易对方,商品,收/支,金额(元),'
    '支付方式,当前状态,交易单号,商户单号,备注';
const wechatRecord = '2026-10-13 12:00:00,商户消费,商店,午餐,支出,12.50,'
    '零钱,支付成功,01234567890123456789,/,/';

void main() {
  test('Full refund tombstone prevents reimport while other reviews preserve bills', () {
    Map<String, Object?> review(String status, {bool removed = false}) => {
      'status': status,
      'payload': jsonEncode({if (removed) 'previous_record': {'import_key': '支付宝:TEST001'}}),
    };
    final removed = BillCsvService.removedRecordFingerprints([
      review('ignored', removed: true),
    ], 1);
    final record = ExpenseRecord(userId: 1, ledgerId: 1, categoryId: 4,
      amount: 10, date: DateTime(2026, 10, 1), type: 'expense', importKey: '支付宝:TEST001');
    expect(removed, contains(BillCsvService.fingerprint(record)));
    expect(BillCsvService.removedRecordFingerprints([
      review('ignored'), review('resolved', removed: true), review('pending', removed: true),
    ], 1), isEmpty);
    record.userId = null;
    expect(removed, contains(BillCsvService.fingerprintForUser(record, 1)));
  });

  test('Fallback review order IDs normalize spaces and reject damaged identifiers', () {
    ImportReviewItem item(String order) => ImportReviewItem.fromMap({
      'id': 1, 'source': '支付宝', 'reason': '金额需要核对',
      'payload': jsonEncode({'original': {'交易号': order}}),
    });
    expect(ImportReviewService.importKeyFor(item('\uFEFF TEST001\t')), '支付宝:TEST001');
    expect(ImportReviewService.importKeyFor(item('1.2345E+22\t')), isNull);
    expect(ImportReviewService.importKeyFor(item('[公式单元格，请粘贴为值]')), isNull);
    expect(ImportReviewService.importKeyFor(item('[数字精度丢失风险]')), isNull);
  });

  test('Export round trip preserves quoted Chinese notes and import identity', () {
    final record = ExpenseRecord(
      id: 1, userId: 1, ledgerId: 1, categoryId: 4,
      type: 'expense', amount: 12.5,
      date: DateTime(2026, 10, 13, 12), title: '午餐',
      note: '备注, "中文"\n第二行', importKey: '微信:01234567890123456789',
    );
    final csv = BillCsvService(DatabaseHelper()).encode([record]);
    final table = BillFileReader.read('bill.csv', utf8.encode(csv)).single;
    expect(table.source, '本软件');
    expect(table.rows.single[7], record.note);
    expect(table.rows.single[9], record.importKey);
  });

  test('WeChat skips descriptions and canonicalizes metadata fields', () {
    final csv = '微信支付账单明细\r\n统计说明\r\n'
        '$wechatHeader\r\n$wechatRecord\r\n';
    final table = BillFileReader.read('微信.csv', utf8.encode(csv)).single;
    expect(table.source, '微信');
    expect(table.headerRow, 3);
    expect(table.headers[3], '商品说明');
    expect(table.headers[5], '金额');
    expect(table.headers[7], '交易状态');
    expect(table.headers[8], '交易号');
    expect(table.rows.first[8], '01234567890123456789');
  });

  test('Alipay GBK supports full width headers, padded cells and trailing column', () {
    const csv = '支付宝交易记录\n'
        '交易时间\t,交易分类\t,交易对方\t,商品说明\t,收/支\t,金额（元）\t,'
        '收/付款方式\t,交易状态\t,交易订单号\t,商家订单号\t,备注\t,\n'
        '2026-10-13 12:00:00,餐饮,商家,咖啡,支出,18.00,余额,交易成功,'
        '00012345678901234567,/,/,\n';
    final table = BillFileReader.read('支付宝.csv', gbk_bytes.encode(csv)).single;
    expect(table.source, '支付宝');
    expect(table.headers, contains('金额'));
    expect(table.headers, contains('支付方式'));
    expect(table.headers, contains('交易号'));
    expect(table.headers.last, '备注');
    expect(table.rows.first[3], '咖啡');
  });

  test('Legacy Alipay retains payment/modification dates and refund amount', () {
    const csv = '支付宝交易记录明细\n'
        '交易号,商家订单号,交易创建时间,付款时间,最近修改时间,交易来源地,'
        '类型,交易对方,商品名称,金额(元),收/支,交易状态,服务费(元),成功退款(元),备注\n'
        '00123,00999,2026-10-13 10:00:00,2026-10-13 10:01:00,'
        '2026-10-13 11:00:00,客户端,即时到账,商店,午餐,30.00,支出,'
        '交易成功,0.00,12.00,部分退款\n';
    final table = BillFileReader.read('账单.csv', gbk_bytes.encode(csv)).single;
    expect(table.source, '支付宝');
    expect(table.headers, containsAll(['交易时间', '付款时间', '最近修改时间',
      '商品说明', '金额', '退款金额']));
    expect(table.rows.first[table.headers.indexOf('退款金额')], '12.00');
  });

  test('Alipay GBK account-only export recognizes the header after 23 description rows', () {
    final prefix = List<String>.generate(23, (index) =>
        '${index == 0 ? '支付宝交易记录' : '账单说明'}${List.filled(10, ',').join()}');
    final csv = '${prefix.join('\r\n')}\r\n'
        '交易时间,交易分类,对方账号,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,\r\n'
        '2026-10-13 12:00:00,餐饮,test@example.invalid,支出,18.00,余额,交易成功,'
        '00000000000000000123,TEST-MERCHANT-001,测试账单,\r\n';
    final table = BillFileReader.read('账单.csv', gbk_bytes.encode(csv)).single;
    expect(table.source, '支付宝');
    expect(table.headerRow, 24);
    expect(table.headers, ['交易时间', '交易分类', '对方账号', '收/支', '金额',
      '支付方式', '交易状态', '交易号', '商家订单号', '备注']);
    expect(table.headers, isNot(contains('交易对方')));
    expect(table.headers, isNot(contains('商品说明')));
    expect(table.rows.first[2], 'test@example.invalid');
    expect(table.rows.first[7], '00000000000000000123');
    expect(table.rows.first.length, 11);
  });

  test('UTF-8 BOM semicolon CSV preserves quoted delimiter and multiline text', () {
    const csv = '\uFEFF支付宝交易记录\nsep=;\n'
        '创建时间;交易对方名称;商品名称;收入/支出;交易金额（元）;'
        '交易状态说明;支付宝交易号;备注\n'
        '2026-10-13 12:00:00;商店;"咖啡;面包";支出;18.00;交易成功;'
        '00012345678901234567;"第一行\n第二行"\n';
    final table = BillFileReader.read('账单.csv', utf8.encode(csv)).single;
    expect(table.source, '支付宝');
    expect(table.headerRow, 3);
    expect(table.headers, ['交易时间', '交易对方', '商品说明', '收/支',
      '金额', '交易状态', '交易号', '备注']);
    expect(table.rows.first[2], '咖啡;面包');
    expect(table.rows.first[7], '第一行\n第二行');
  });

  test('UTF-16 LE tab-delimited files preserve supplementary characters', () {
    final csv = '微信支付账单明细\r\n'
        '${wechatHeader.replaceAll(',', '\t')}\r\n'
        '${wechatRecord.replaceAll('午餐', '午餐🍵').replaceAll(',', '\t')}\r\n';
    final table = BillFileReader.read('微信.csv', utf16Bytes(csv)).single;
    expect(table.source, '微信');
    expect(table.headerRow, 2);
    expect(table.rows.first[3], '午餐🍵');
    expect(table.rows.first[8], '01234567890123456789');
  });

  test('UTF-16 BE and UTF-16 without BOM detect byte order', () {
    const csv = '$wechatHeader\n$wechatRecord\n';
    for (final littleEndian in [true, false]) {
      for (final bom in [true, false]) {
        final table = BillFileReader.read('账单.csv',
            utf16Bytes(csv, littleEndian: littleEndian, bom: bom)).single;
        expect(table.source, '微信');
        expect(table.rows.first[2], '商店');
        expect(table.rows.first[5], '12.50');
      }
    }
  });

  test('Split income and expense exports keep both columns and original values', () {
    const csv = '支付宝交易明细\n'
        '交易创建时间,交易对方,商品名称,收入（元）,支出（元）,交易号,交易状态\n'
        '2026-10-13 12:00:00,商店,退款,12.00,,00123,退款成功\n'
        '2026-10-13 13:00:00,商店,午餐,,30.00,00124,交易成功\n';
    final table = BillFileReader.read('账单.csv', utf8.encode(csv)).single;
    expect(table.source, '支付宝');
    expect(table.headers, containsAll(['收入金额', '支出金额']));
    expect(table.rows[0][3], '12.00');
    expect(table.rows[0][4], '');
    expect(table.rows[1][3], '');
    expect(table.rows[1][4], '30.00');
  });

  test('Colliding time aliases retain each original column', () {
    const csv = '交易创建时间,交易时间,交易对方,收/支,金额(元),交易订单号\n'
        '2026-10-13 10:00:00,2026-10-13 10:01:00,商店,支出,12,00123\n';
    final table = BillFileReader.read('账单.csv', utf8.encode(csv)).single;
    expect(table.headers[0], '交易创建时间');
    expect(table.headers[1], '交易时间');
    expect(table.headers.toSet().length, table.headers.length);
  });

  test('Excel supports typed dates and keeps text trade identities', () {
    final excel = Excel.createExcel();
    final sheet = excel['账单'];
    final headers = ['ID', '账本ID', '类型', '金额', '分类ID', '账户ID',
      '日期', '备注', '名称', '来源标识'];
    for (var i = 0; i < headers.length; i++) {
      sheet.updateCell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
          TextCellValue(headers[i]));
    }
    final values = <CellValue>[
      IntCellValue(1), IntCellValue(1), TextCellValue('expense'),
      DoubleCellValue(12.5), IntCellValue(4), TextCellValue(''),
      DateTimeCellValue.fromDateTime(DateTime(2026, 10, 13, 12)),
      TextCellValue('午餐'), TextCellValue('午餐'),
      TextCellValue('微信:01234567890123456789'),
    ];
    for (var i = 0; i < values.length; i++) {
      sheet.updateCell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 1),
          values[i]);
    }
    final table = BillFileReader.read('bill.xlsx', excel.encode()!).single;
    expect(table.sheet, '账单');
    expect(table.rows.first[6], '2026-10-13T12:00:00.000');
    expect(table.rows.first[9], '微信:01234567890123456789');
  });

  test('Unrecognized header diagnostics describe fields without revealing rows', () {
    expect(() => BillFileReader.read('file.csv',
        utf8.encode('日期,金额\n2026-10-13,私人备注')),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message',
        allOf(contains('UTF-8'), contains('金额'), isNot(contains('私人备注'))),
      )));
  });

  test('Malformed quoted CSV reports detected header row and encoding', () {
    final csv = '微信支付账单明细\n$wechatHeader\n'
        '2026-10-13 12:00:00,商户消费,商店,"午餐';
    expect(() => BillFileReader.read('微信.csv', utf8.encode(csv)),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message',
        allOf(contains('第2行'), contains('UTF-8'), contains('引号')),
      )));
  });

  test('Wrong archive and old Excel formats receive an actionable message', () {
    expect(() => BillFileReader.read('bill.csv', [0x50, 0x4B, 0x03, 0x04]),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message', contains('解压'))));
    expect(() => BillFileReader.read('bill.xls', [0xD0, 0xCF, 0x11, 0xE0]),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message', contains('另存为'))));
  });

  test('Incomplete UTF-16 content is rejected instead of producing corrupted rows', () {
    expect(() => BillFileReader.read('bill.csv', [0xFF, 0xFE, 0x2C]),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message', contains('UTF-16文件不完整'))));
  });

  test('Platform identity stays stable across edits and is scoped by user', () {
    ExpenseRecord record(int user, int category, double amount) => ExpenseRecord(
      userId: user, ledgerId: 1, categoryId: category, amount: amount,
      date: DateTime(2026, 10, 13), type: 'expense', importKey: '微信:00123',
    );
    expect(BillCsvService.fingerprint(record(1, 4, 10)),
        BillCsvService.fingerprint(record(1, 5, 20)));
    expect(BillCsvService.fingerprint(record(1, 4, 10)),
        isNot(BillCsvService.fingerprint(record(2, 4, 10))));
  });
}
