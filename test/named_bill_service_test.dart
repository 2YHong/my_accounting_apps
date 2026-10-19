import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/category.dart';
import 'package:my_accounting_app/models/import_review.dart';
import 'package:my_accounting_app/services/bill_csv_service.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';
import 'package:my_accounting_app/services/import_review_service.dart';
import 'package:my_accounting_app/services/named_bill_service.dart';

List<Category> categories() => [
  Category(id: 1, userId: 1, name: '其他支出', type: 'expense'),
  Category(id: 2, userId: 1, name: '其他收入', type: 'income'),
  Category(id: 3, userId: 1, name: '餐饮', type: 'expense'),
  Category(id: 4, userId: 1, name: '工资', type: 'income'),
];

BillTable table(List<List<String>> rows, {String name = 'export.csv'}) {
  final csv = const ListToCsvConverter().convert([
    BillFileReader.namedHeaders,
    ...rows,
  ]);
  return BillFileReader.read(name, utf8.encode('\uFEFF$csv')).single;
}

Future<BillImportPreview> preview(
  BillTable input, {
  Set<String> seen = const {},
  Set<String> seenReviews = const {},
  int? accountId,
}) => NamedBillService.buildPreview(
  input,
  userId: 1,
  ledgerId: 10,
  categories: categories(),
  seen: seen,
  seenReviews: seenReviews,
  accountId: accountId,
);

void main() {
  test(
    'description is title; blank description uses original category',
    () async {
      final input = table([
        ['支出', '12.50', '2026/10/18 12:30:25', '餐饮', '', '午饭, "套餐"\n第二行', '现金'],
        ['收入', '3000.00', '2026/10/18 18:00:00', '工资', '', '  ', '现金'],
      ]);
      expect(input.source, BillFileReader.namedSource);
      final result = await preview(input);
      expect(result.errors, isEmpty);
      expect(result.reviewItems, isEmpty);
      expect(result.records.map((r) => r.title), ['午饭, "套餐"\n第二行', '工资']);
      expect(result.records.map((r) => r.type), ['expense', 'income']);
      expect(result.records.first.amount, 12.5);
      expect(result.records.first.date, DateTime(2026, 10, 18, 12, 30, 25));
      expect(result.records.first.categoryId, 3);
      expect(result.newCategories, isEmpty);
    },
  );

  test(
    'categories are planned without mutating supplied data or inventing account balances',
    () async {
      final original = categories();
      final input = table([
        ['支出', '20', '2026/10/18', '水电网杂费', '家庭;必要', '电费', '银行卡'],
        ['支出', '30', '2026/10/18', '水电网杂费', '', '', '现金'],
        ['收入', '5', '2026/10/18', '水电网杂费', '', '', '现金'],
      ]);
      final result = await NamedBillService.buildPreview(
        input,
        userId: 1,
        ledgerId: 10,
        categories: original,
      );
      expect(original.length, 4);
      expect(result.newCategories.length, 2);
      expect(result.newCategories.map((c) => c.type), ['expense', 'income']);
      expect(result.records[0].categoryId, result.records[1].categoryId);
      expect(result.records[2].categoryId, isNot(result.records[0].categoryId));
      expect(result.records.every((r) => r.assetAccountId == null), isTrue);
      expect(result.records.first.note, '标签：家庭;必要\n原账户：银行卡');
      expect(result.records[1].title, '水电网杂费');
      final linked = await preview(input, accountId: 44);
      expect(linked.records.every((r) => r.assetAccountId == 44), isTrue);
    },
  );

  test(
    'renaming, reordering and decimal spelling do not duplicate an unchanged bill',
    () async {
      final first = [
        '支出',
        '12.50',
        '2026/10/18 12:00:00',
        '餐饮',
        '',
        '午饭',
        '现金',
      ];
      final second = ['收入', '20', '2026/10/18 13:00:00', '工资', '', '补贴', '现金'];
      final initial = await preview(table([first, second]));
      final changedSpelling = List<String>.of(first)..[1] = '12.5';
      final repeat = await preview(
        table([second, changedSpelling], name: 'renamed.csv'),
        seen: initial.records.map(BillCsvService.fingerprint).toSet(),
      );
      expect(repeat.records, isEmpty);
      expect(repeat.newCategories, isEmpty);
      expect(repeat.duplicates, 2);
    },
  );

  test(
    'two identical source rows survive once each and remain idempotent',
    () async {
      final row = ['支出', '10', '2026/10/18', '餐饮', '', '同一秒两笔', '现金'];
      final initial = await preview(table([row, row]));
      expect(initial.records.length, 2);
      expect(initial.records.map((r) => r.importKey).toSet().length, 2);
      final repeat = await preview(
        table([row, row]),
        seen: initial.records.map(BillCsvService.fingerprint).toSet(),
      );
      expect(repeat.duplicates, 2);
      expect(repeat.records, isEmpty);
    },
  );

  test(
    'invalid money, impossible dates and transfers retain original rows for review',
    () async {
      final result = await preview(
        table([
          for (final amount in ['-2', '0', '1.001', 'NaN', '1e3', '1,2'])
            ['支出', amount, '2026/10/18', '餐饮', '', '待核对金额', '现金'],
          ['支出', '10', '2026/02/30', '餐饮', '', '待核对日期', '现金'],
          ['转账', '10', '2026/10/18', '转账', '', '待核对转账', '现金'],
        ]),
      );
      expect(result.records, isEmpty);
      expect(result.newCategories, isEmpty);
      expect(result.reviewItems.length, 8);
      for (final draft in result.reviewItems) {
        final item = ImportReviewItem.fromMap({'id': 1, ...draft.toMap()});
        expect(ImportReviewService.importKeyFor(item), draft.rowKey);
        expect(item.original['描述'], isNotEmpty);
      }
      final again = await preview(
        table([
          ['支出', '-2', '2026/10/18', '餐饮', '', '待核对金额', '现金'],
        ]),
        seenReviews: result.reviewItems.map((r) => r.rowKey).toSet(),
      );
      expect(again.duplicates, 1);
      expect(again.reviewItems, isEmpty);
    },
  );

  test(
    'manual category override retains original category and title fallback',
    () async {
      final result = await NamedBillService.buildPreview(
        table([
          ['支出', '10', '2026/10/18', '水电网杂费', '', '', '现金'],
        ]),
        userId: 1,
        ledgerId: 10,
        categories: categories(),
        preserveCategories: false,
        expenseCategoryId: 3,
        incomeCategoryId: 4,
      );
      expect(result.records.single.categoryId, 3);
      expect(result.records.single.title, '水电网杂费');
      expect(result.records.single.note, contains('原分类：水电网杂费'));
      expect(result.newCategories, isEmpty);
    },
  );

  test('named export also works as XLSX and with reordered columns', () async {
    final workbook = Excel.createExcel();
    workbook['Sheet1'].appendRow([
      for (final name in BillFileReader.namedHeaders.reversed)
        TextCellValue(name),
    ]);
    workbook['Sheet1'].appendRow([
      for (final value in [
        '支出',
        '10.00',
        '2026/10/18 12:00:00',
        '餐饮',
        '',
        '',
        '现金',
      ].reversed)
        TextCellValue(value),
    ]);
    final input = BillFileReader.read('export.xlsx', workbook.encode()!).single;
    final result = await preview(input);
    expect(result.records.single.title, '餐饮');
    expect(result.records.single.amount, 10);
  });

  test(
    'XLSX numeric amounts and typed date cells retain dates and title fallback',
    () async {
      final workbook = Excel.createExcel();
      workbook['Sheet1'].appendRow([
        for (final name in BillFileReader.namedHeaders) TextCellValue(name),
      ]);
      workbook['Sheet1'].appendRow([
        TextCellValue('支出'),
        DoubleCellValue(10.50),
        DateTimeCellValue(
          year: 2026,
          month: 10,
          day: 18,
          hour: 12,
          minute: 30,
          second: 25,
        ),
        TextCellValue('餐饮'),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue('现金'),
      ]);
      workbook['Sheet1'].appendRow([
        TextCellValue('收入'),
        IntCellValue(20),
        DateCellValue(year: 2026, month: 10, day: 18),
        TextCellValue('工资'),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue('现金'),
      ]);
      final input = BillFileReader.read(
        'typed.xlsx',
        workbook.encode()!,
      ).single;
      final result = await preview(input);
      expect(result.reviewItems, isEmpty);
      expect(result.records.map((r) => r.date), [
        DateTime(2026, 10, 18, 12, 30, 25),
        DateTime(2026, 10, 18),
      ]);
      expect(result.records.map((r) => r.amount), [10.5, 20]);
      expect(result.records.map((r) => r.title), ['餐饮', '工资']);
    },
  );

  test(
    'supplied CSV is preserved row by row and repeated import adds nothing',
    () async {
      final path = Platform.environment['ACCOUNTING_NAMED_CSV'];
      final bytes = await File(path!).readAsBytes();
      final input = BillFileReader.read('2026.csv', bytes).single;
      final result = await preview(input);
      expect(result.records.length, 305);
      expect(result.records.where((r) => r.type == 'expense').length, 298);
      expect(result.records.where((r) => r.type == 'income').length, 7);
      expect(result.errors, isEmpty);
      expect(result.skipped, isEmpty);
      expect(result.reviewItems, isEmpty);
      var fallbackTitles = 0;
      for (var i = 0; i < input.rows.length; i++) {
        final row = input.rows[i];
        final record = result.records[i];
        final description = row[5].trim();
        expect(record.title, description.isEmpty ? row[3].trim() : description);
        if (description.isEmpty) fallbackTitles++;
        final parts = row[1].split('.');
        final expectedCents =
            int.parse(parts[0]) * 100 +
            int.parse((parts.length == 1 ? '' : parts[1]).padRight(2, '0'));
        expect((record.amount * 100).round(), expectedCents);
        expect(record.date, DateTime.parse(row[2].replaceAll('/', '-')));
        expect(record.assetAccountId, isNull);
        final mapped = [
          ...categories(),
          ...result.newCategories,
        ].singleWhere((c) => c.id == record.categoryId);
        expect(mapped.name, row[3].trim());
      }
      final repeated = await preview(
        input,
        seen: result.records.map(BillCsvService.fingerprint).toSet(),
      );
      expect(repeated.records, isEmpty);
      expect(repeated.duplicates, 305);
      // Summary only; the user's transaction details never become test fixtures.
      stdout.writeln(
        'Supplied CSV: 305 records verified; empty descriptions using category: $fallbackTitles; repeat import: 305 duplicates.',
      );
    },
    skip: !Platform.environment.containsKey('ACCOUNTING_NAMED_CSV'),
  );
}
