import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../database/database_helper.dart';
import '../models/category.dart';
import '../models/expense_record.dart';
import '../models/import_review.dart';
import '../models/refund_net.dart';
import 'bill_category_classifier.dart';
import 'bill_csv_service.dart';
import 'bill_file_reader.dart';
import 'bill_investment_filter.dart';

/// Imports already-classified personal exports without pretending they are
/// payment-platform statements. No source IDs or account balances are invented.
class NamedBillService {
  final DatabaseHelper db;
  NamedBillService(this.db);

  Future<BillImportPreview> preview(
    BillTable table, {
    required int ledgerId,
    int? accountId,
    int? expenseCategoryId,
    int? incomeCategoryId,
    bool autoClassify = true,
    String fileName = '',
  }) async {
    final user = await db.getCurrentUser();
    final ledgers = await db.getAllLedgers(userId: user.id);
    final categories = await BillCategoryClassifier.ensureFallbacks(
      db,
      user.id!,
    );
    final accounts = await db.getAllAssetAccounts(userId: user.id);
    if (!ledgers.any((l) => l.id == ledgerId)) {
      throw const FormatException('请选择有效账本');
    }
    if (accountId != null && !accounts.any((a) => a.id == accountId)) {
      throw const FormatException('请选择有效账户');
    }
    if (!autoClassify &&
        (!categories.any(
              (c) => c.id == expenseCategoryId && c.type == 'expense',
            ) ||
            !categories.any(
              (c) => c.id == incomeCategoryId && c.type == 'income',
            ))) {
      throw const FormatException('请选择有效的收支分类');
    }
    final database = await db.database;
    final rows = await database.query(
      'expense_records',
      where: 'ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)',
      whereArgs: [user.id],
    );
    final reviews = await database.query(
      'import_reviews',
      where: 'user_id = ?',
      whereArgs: [user.id],
    );
    final seen =
        rows
            .map(ExpenseRecord.fromMap)
            .map((r) => BillCsvService.fingerprintForUser(r, user.id))
            .toSet()
          ..addAll(BillCsvService.removedRecordFingerprints(reviews, user.id));
    return buildPreview(
      table,
      userId: user.id!,
      ledgerId: ledgerId,
      categories: categories,
      accountId: accountId,
      fileName: fileName,
      expenseCategoryId: expenseCategoryId,
      incomeCategoryId: incomeCategoryId,
      preserveCategories: autoClassify,
      seen: seen,
      seenReviews: reviews.map((r) => r['row_key'] as String).toSet(),
    );
  }

  static DateTime? _date(String value) {
    final match = RegExp(
      r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})'
      r'(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(\.\d{1,6})?)?)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i] ?? '0')];
    final date = DateTime(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (parts[0] < 1900 ||
        parts[0] > 2200 ||
        date.year != parts[0] ||
        date.month != parts[1] ||
        date.day != parts[2] ||
        date.hour != parts[3] ||
        date.minute != parts[4] ||
        date.second != parts[5]) {
      return null;
    }
    final fraction = (match[7] ?? '.').substring(1).padRight(6, '0');
    return date.add(Duration(microseconds: int.parse(fraction)));
  }

  static int? _cents(String value) {
    final text = value.replaceFirst(RegExp(r'^[¥￥]\s*'), '');
    if (!RegExp(
      r'^\+?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$',
    ).hasMatch(text)) {
      return null;
    }
    return refundMoneyCents(text);
  }

  /// Pure preview: missing named categories receive temporary negative IDs.
  /// Only the final database transaction may create them and resolve those IDs.
  static Future<BillImportPreview> buildPreview(
    BillTable table, {
    required int userId,
    required int ledgerId,
    required List<Category> categories,
    int? accountId,
    int? expenseCategoryId,
    int? incomeCategoryId,
    bool preserveCategories = true,
    String fileName = '',
    Set<String> seen = const {},
    Set<String> seenReviews = const {},
  }) async {
    if (table.source != BillFileReader.namedSource ||
        !table.headers.toSet().containsAll(BillFileReader.namedHeaders)) {
      throw const FormatException('请选择包含类型、金额、日期、分类、标签、描述和账户的表格');
    }
    final owned = categories
        .where((c) => c.userId == userId && c.id != null && c.id! > 0)
        .toList();
    Category fallback(String type) => owned.firstWhere(
      (c) =>
          c.type == type && c.name == BillCategoryClassifier.fallbackName(type),
      orElse: () => throw const FormatException('请先准备其他收入和其他支出分类'),
    );
    final expenseFallback = fallback('expense');
    final incomeFallback = fallback('income');
    final pending = <String, Category>{};
    final records = <ExpenseRecord>[];
    final reviews = <ImportReviewDraft>[];
    final errors = <String>[];
    final skipped = <String>[];
    final known = Set<String>.of(seen);
    final knownReviews = Set<String>.of(seenReviews);
    final occurrences = <String, int>{};
    var duplicates = 0;
    Category resolveCategory(String type, String original) {
      final override = type == 'expense' ? expenseCategoryId : incomeCategoryId;
      if (!preserveCategories) {
        return owned.firstWhere(
          (c) => c.id == override && c.type == type,
          orElse: () => throw const FormatException('请选择有效的收支分类'),
        );
      }
      final name = original.isEmpty
          ? BillCategoryClassifier.fallbackName(type)
          : original;
      final existing = owned
          .where((c) => c.type == type && BillFileReader.clean(c.name) == name)
          .firstOrNull;
      if (existing != null) return existing;
      final key = jsonEncode([type, name]);
      return pending.putIfAbsent(
        key,
        () => Category(
          id: -(pending.length + 1),
          name: name,
          type: type,
          userId: userId,
          icon: 'other',
        ),
      );
    }

    for (var index = 0; index < table.rows.length; index++) {
      final row = table.rows[index];
      if (row.every((v) => BillFileReader.clean(v).isEmpty)) continue;
      final number = table.headerRow + index + 1;
      String value(String name) {
        final column = table.headers.indexOf(name);
        return column >= 0 && column < row.length
            ? BillFileReader.clean(row[column])
            : '';
      }

      final original = <String, String>{};
      for (var column = 0; column < row.length; column++) {
        final name = column < table.originalHeaders.length
            ? table.originalHeaders[column]
            : '未命名列';
        var key = name;
        var suffix = 2;
        while (original.containsKey(key)) {
          key = '$name（$suffix）';
          suffix++;
        }
        original[key] = row[column];
      }
      final type = switch (value('类型')) {
        '支出' || 'expense' => 'expense',
        '收入' || 'income' => 'income',
        _ => null,
      };
      final cents = _cents(value('金额'));
      final date = _date(value('日期'));
      final categoryName = value('分类');
      final description = value('描述');
      final tags = value('标签');
      final sourceAccount = value('账户');
      final extraColumns = <String>[
        for (var i = 0; i < table.headers.length && i < row.length; i++)
          if (!BillFileReader.namedHeaders.contains(table.headers[i]) &&
              BillFileReader.clean(row[i]).isNotEmpty)
            '${table.headers[i]}：${row[i]}',
      ]..sort();
      final identity = jsonEncode([
        type ?? value('类型'),
        cents ?? value('金额'),
        date?.toIso8601String() ?? value('日期'),
        categoryName,
        tags,
        description,
        sourceAccount,
        extraColumns,
      ]);
      final digest = await Sha256().hash(utf8.encode(identity));
      final hash = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final occurrence = occurrences.update(
        hash,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      // The occurrence keeps two genuinely identical rows in the same export.
      // Filename and row position do not affect identity on a later import.
      final importKey = '通用表格:v1:$hash:$occurrence';
      final fingerprint = jsonEncode([userId, importKey]);
      if (known.contains(fingerprint) || knownReviews.contains(importKey)) {
        duplicates++;
        continue;
      }
      final reasons = <String>[
        if (table.headers.toSet().length != table.headers.length) '表头存在重复列',
        if (row.skip(table.headers.length).any((v) => v.trim().isNotEmpty))
          '记录列数超出表头，原始整行已保留',
        if (type == null) '收支类型无法识别，转账等项目请单独核对',
        if (cents == null || cents <= 0) '金额须大于0且最多两位小数，请核对原始金额',
        if (date == null) '日期格式无效，请核对原始日期',
      ];
      if (reasons.isNotEmpty) {
        final reason = reasons.join('；');
        reviews.add(
          ImportReviewDraft(
            userId: userId,
            source: BillFileReader.namedSource,
            rowKey: importKey,
            importKey: importKey,
            reason: reason,
            fileName: fileName,
            original: original,
            ledgerId: ledgerId,
            accountId: accountId,
            expenseCategoryId: expenseFallback.id!,
            incomeCategoryId: incomeFallback.id!,
          ),
        );
        knownReviews.add(importKey);
        errors.add('第$number行：$reason');
        continue;
      }
      if (BillInvestmentFilter.isInvestment(
        category: categoryName,
        title: description,
        description: '',
        counterparty: '',
      )) {
        skipped.add('第$number行：明确的投资相关支出或收入，不计入日常收支');
        continue;
      }
      final category = resolveCategory(type!, categoryName);
      final title = description.isNotEmpty
          ? description
          : categoryName.isNotEmpty
          ? categoryName
          : category.name;
      records.add(
        ExpenseRecord(
          userId: userId,
          ledgerId: ledgerId,
          categoryId: category.id!,
          type: type,
          amount: cents! / 100,
          date: date!,
          title: title,
          assetAccountId: accountId,
          importKey: importKey,
          note: [
            if (tags.isNotEmpty) '标签：$tags',
            if (sourceAccount.isNotEmpty) '原账户：$sourceAccount',
            if (!preserveCategories && categoryName.isNotEmpty)
              '原分类：$categoryName',
            ...extraColumns,
          ].join('\n'),
        ),
      );
      known.add(fingerprint);
    }
    return BillImportPreview(
      records,
      errors,
      duplicates,
      skipped: skipped,
      reviewItems: reviews,
      newCategories: pending.values.toList(),
    );
  }
}
