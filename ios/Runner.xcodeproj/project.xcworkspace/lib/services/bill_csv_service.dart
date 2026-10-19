import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/category.dart';
import '../models/import_review.dart';
import '../models/refund_net.dart';
import 'bill_category_classifier.dart';
import 'bill_investment_filter.dart';

// Shared notification so retained bill/statistics pages reload after import.
final billDataRevision = ValueNotifier<int>(0);

class BillImportPreview {
  final List<ExpenseRecord> records;
  final List<String> errors;
  final int duplicates;
  final List<String> skipped;
  final List<ImportReviewDraft> reviewItems;
  final List<RefundImportPlan> refundPlans;
  final List<Category> newCategories;
  BillImportPreview(this.records, this.errors, this.duplicates,
      {this.skipped = const [], this.reviewItems = const [], this.refundPlans = const [],
       this.newCategories = const []});
  int get refundUpdateCount => refundPlans.where((p) => !p.isNew).length;
  int get fullyRefundedCount => records.where((record) => record.type == 'expense' &&
    record.amount == 0 && record.refundGrossCents != null && record.refundGrossCents! > 0 &&
    record.refundTotalCents == record.refundGrossCents).length +
    refundPlans.where((plan) => !plan.isNew && plan.fullyRefunded).length;
}

class BillCsvService {
  final DatabaseHelper db;
  BillCsvService(this.db);
  static const headers = ['ID', '账本ID', '类型', '金额', '分类ID', '账户ID', '日期', '备注', '名称', '来源标识', '分类名称', '原付款金额(分)', '累计退款金额(分)', '退款计算依据'];

  static List<Object> _refundExportFields(ExpenseRecord record) {
    final gross = record.refundGrossCents;
    final refunded = record.refundTotalCents;
    if (record.type != 'expense' || gross == null || gross <= 0 ||
        refunded == null || refunded < 0 || refunded > gross ||
        !['none', 'cumulative', 'events', 'export'].contains(record.refundBasis) ||
        !(record.importKey?.isNotEmpty ?? false) || !record.amount.isFinite || record.amount < 0 ||
        (record.amount * 100 - (record.amount * 100).round()).abs() > .000001 ||
        refundMoneyCents(record.amount.toStringAsFixed(2)) != gross - refunded) {
      // An adjusted amount remains the user's actual amount. Its old audit
      // metadata belongs in a complete backup, not a contradictory CSV row.
      return const ['', '', ''];
    }
    return [gross, refunded, record.refundBasis!];
  }

  String encode(List<ExpenseRecord> records, {Map<int, String> categoryNames = const {}}) => '\uFEFF${const ListToCsvConverter().convert([
    headers,
    ...records.map((r) => [r.id, r.ledgerId, r.type, r.amount, r.categoryId,
      r.assetAccountId ?? '', r.date.toIso8601String(), r.note ?? '', r.title ?? '', r.importKey ?? '', categoryNames[r.categoryId] ?? '',
      ..._refundExportFields(r)]),
  ])}';

  static String fingerprint(ExpenseRecord r) => (r.importKey?.isNotEmpty ?? false)
    ? jsonEncode([r.userId, r.importKey]) : jsonEncode([
    r.ledgerId, r.type, r.amount, r.categoryId, r.assetAccountId,
    r.date.toIso8601String(), r.note ?? '', r.title ?? '',
  ]);

  // Legacy bills can have null user_id; callers already scope by owned ledger.
  static String fingerprintForUser(ExpenseRecord r, int? userId) =>
    (r.importKey?.isNotEmpty ?? false) ? jsonEncode([userId, r.importKey]) : fingerprint(r);

  // A fully refunded bill must not reappear when an older statement is imported.
  static Set<String> removedRecordFingerprints(List<Map<String, Object?>> reviews, int? userId) {
    final keys = <String>{};
    for (final row in reviews) {
      if (row['status'] != 'ignored') continue;
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final previous = payload['previous_record'];
      if (previous is! Map) continue;
      final key = previous['import_key'];
      if (key is String && key.isNotEmpty) keys.add(jsonEncode([userId, key]));
    }
    return keys;
  }

  Future<BillImportPreview> preview(String text) async {
    text = text.replaceFirst(RegExp(r'^\uFEFF'), '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false,
      allowInvalid: false).convert(text);
    return previewRows(rows);
  }

  Future<BillImportPreview> previewRows(List<List<dynamic>> rows) async {
    if (rows.isEmpty) throw const FormatException('账单文件为空');
    final header = rows.first.map((v) => v.toString().trim()).toList();
    if (header.toSet().length != header.length) {
      throw const FormatException('表头存在重复列');
    }
    for (final name in ['账本ID', '类型', '金额', '分类ID', '账户ID', '日期', '备注']) {
      if (!header.contains(name)) throw FormatException('缺少表头：$name。请选择本软件导出的CSV文件');
    }
    final user = await db.getCurrentUser();
    final ledgers = {for (final l in await db.getAllLedgers(userId: user.id)) l.id: l};
    final categoryList = await BillCategoryClassifier.ensureFallbacks(db, user.id!);
    final categories = {for (final c in categoryList) c.id: c};
    final accounts = {for (final a in await db.getAllAssetAccounts(userId: user.id)) a.id: a};
    final seen = (await db.getAllRecords())
        .where((record) => ledgers.containsKey(record.ledgerId))
        .map((record) => fingerprintForUser(record, user.id)).toSet();
    final database = await db.database;
    for (final source in await database.query('refund_sources', columns: ['import_key'],
        where: 'user_id = ?', whereArgs: [user.id])) {
      seen.add(jsonEncode([user.id, source['import_key']]));
    }
    seen.addAll(removedRecordFingerprints(await database.query('import_reviews',
      where: 'user_id = ? AND status = ?', whereArgs: [user.id, 'ignored']), user.id));
    final records = <ExpenseRecord>[];
    final errors = <String>[];
    final skipped = <String>[];
    var duplicates = 0;
    for (var i = 1; i < rows.length; i++) {
      final row = List<dynamic>.from(rows[i]);
      while (row.length > header.length && row.last.toString().trim().isEmpty) { row.removeLast(); }
      while (row.length < header.length) { row.add(''); }
      if (row.every((v) => v.toString().trim().isEmpty)) continue;
      try {
        if (row.length != header.length) throw const FormatException('列数与表头不一致');
        String value(String key) {
          final index = header.indexOf(key);
          return index < 0 ? '' : row[index].toString();
        }
        int id(String key) {
          final raw = value(key).trim();
          final n = int.tryParse(raw) ?? (RegExp(r'^\d+\.0+$').hasMatch(raw) ? double.parse(raw).toInt() : null);
          if (n == null || n <= 0) throw FormatException('$key必须是正整数');
          return n;
        }
        final exportedCategory = value('分类名称').trim();
        final categoryName = exportedCategory.isNotEmpty ? exportedCategory
          : categories[int.tryParse(value('分类ID').trim())]?.name ?? '';
        if (BillInvestmentFilter.isInvestment(category: categoryName,
            title: value('名称'), description: value('备注'))) {
          skipped.add('第${i + 1}条CSV记录：明确的投资相关支出或收入，不计入日常收支');
          continue;
        }
        final ledgerId = id('账本ID');
        final categoryId = id('分类ID');
        final accountId = value('账户ID').trim().isEmpty ? null : id('账户ID');
        final type = switch (value('类型').trim()) {
          '支出' => 'expense', '收入' => 'income', final other => other,
        };
        if (type != 'expense' && type != 'income') throw const FormatException('类型必须为expense/income或支出/收入');
        final amount = double.tryParse(value('金额').trim());
        final grossRaw = value('原付款金额(分)').trim();
        final refundedRaw = value('累计退款金额(分)').trim();
        final gross = grossRaw.isEmpty ? null : int.tryParse(grossRaw);
        final refunded = refundedRaw.isEmpty ? null : int.tryParse(refundedRaw);
        final hasRefundMetadata = grossRaw.isNotEmpty || refundedRaw.isNotEmpty || value('退款计算依据').trim().isNotEmpty;
        if (hasRefundMetadata && (gross == null || gross <= 0 || refunded == null || refunded < 0 ||
            refunded > gross || type != 'expense' || value('来源标识').trim().isEmpty ||
            !['none', 'cumulative', 'events', 'export'].contains(value('退款计算依据').trim()) ||
            refundMoneyCents(value('金额')) != gross - refunded)) {
          throw const FormatException('退款净额信息不完整或与金额不一致，请使用原导出文件');
        }
        if (amount == null || !amount.isFinite || amount < 0 || (amount == 0 && !hasRefundMetadata)) throw const FormatException('金额必须为有效正数，全额退款仅接受完整净额信息');
        if ((amount * 100 - (amount * 100).round()).abs() > .000001) throw const FormatException('金额最多支持两位小数');
        final rawDate = value('日期').trim();
        final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$').firstMatch(rawDate);
        final date = DateTime.tryParse(rawDate);
        if (match == null || date == null || date.year < 1900 || date.year > 2200) throw const FormatException('日期格式应为1900年至2200年间的YYYY-MM-DD或ISO日期时间');
        final calendar = DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
        if (calendar.year != int.parse(match[1]!) || calendar.month != int.parse(match[2]!) || calendar.day != int.parse(match[3]!)) {
          throw const FormatException('日期不存在');
        }
        if (!ledgers.containsKey(ledgerId)) throw const FormatException('账本ID不存在或不属于当前用户');
        // Same-app exports retain an existing category. Deleted categories can
        // be recovered by their exported name, or by the conservative rules.
        final category = BillCategoryClassifier.choose(categories: categoryList,
          type: type, preservedCategoryId: categories[categoryId]?.type == type ? categoryId : null,
          originalCategory: value('分类名称'), title: value('名称'), description: value('备注'))!;
        if (accountId != null && !accounts.containsKey(accountId)) throw const FormatException('账户ID不存在或不属于当前用户');
        final record = ExpenseRecord(ledgerId: ledgerId, type: type, amount: amount,
          categoryId: category.id!, assetAccountId: accountId, date: date,
          note: value('备注'), title: value('名称'), userId: user.id,
          refundGrossCents: gross, refundTotalCents: refunded,
          refundBasis: hasRefundMetadata ? 'export' : null,
          importKey: value('来源标识').trim().isEmpty ? null : value('来源标识').trim());
        if (!seen.add(fingerprint(record))) { duplicates++; continue; }
        records.add(record);
      } on FormatException catch (e) {
        errors.add('第${i + 1}条CSV记录：${e.message}');
      }
    }
    return BillImportPreview(records, errors, duplicates, skipped: skipped);
  }

  Future<int> importRecords(List<ExpenseRecord> records,
      {List<ImportReviewDraft> reviewItems = const [], List<RefundImportPlan> refundPlans = const []}) async =>
      (await importPreview(BillImportPreview(records, const [], 0,
        reviewItems: reviewItems, refundPlans: refundPlans))).inserted;

  Future<BillImportResult> importPreview(BillImportPreview preview) async {
    final records = preview.records;
    final reviewItems = preview.reviewItems;
    final refundPlans = preview.refundPlans;
    final user = await db.getCurrentUser();
    final database = await db.database;
    var queueChanged = false;
    final result = await database.transaction((txn) async {
      final reviewRows = await txn.query('import_reviews',
          columns: ['row_key', 'status', 'payload'], where: 'user_id = ?', whereArgs: [user.id]);
      final existing = (await txn.query('expense_records',
          where: 'ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)',
          whereArgs: [user.id]))
        .map((row) => fingerprintForUser(ExpenseRecord.fromMap(row), user.id)).toSet();
      existing.addAll(removedRecordFingerprints(reviewRows, user.id));
      final sources = await txn.query('refund_sources', where: 'user_id = ?', whereArgs: [user.id]);
      existing.addAll(sources.map((s) => jsonEncode([user.id, s['import_key']])));
      var inserted = 0;
      var updated = 0;
      var fullyRefunded = 0;
      var queued = 0;
      final plannedKeys = refundPlans.map((p) => p.importKey).toSet();
      final pendingCategories = {for (final c in preview.newCategories) c.id: c};
      if (pendingCategories.length != preview.newCategories.length) {
        throw const FormatException('待导入分类重复，请重新预览');
      }
      final resolvedCategories = <int, int>{};
      for (final incoming in records) {
        var r = incoming;
        if (plannedKeys.contains(r.importKey)) continue;
        if (r.userId != user.id) throw const FormatException('当前用户已变化，请重新预览账单');
        final validNet = r.type == 'expense' && r.refundGrossCents != null &&
            r.refundGrossCents! > 0 && r.refundTotalCents != null &&
            r.refundTotalCents! >= 0 && r.refundTotalCents! <= r.refundGrossCents! &&
            refundMoneyCents(r.amount.toStringAsFixed(2)) == r.refundGrossCents! - r.refundTotalCents! &&
            r.refundBasis == 'export' && (r.importKey?.isNotEmpty ?? false);
        if ((r.refundGrossCents != null || r.refundTotalCents != null || r.refundBasis != null) && !validNet) {
          throw const FormatException('CSV退款净额数据无效，请重新预览');
        }
        if (!r.amount.isFinite || r.amount < 0 || (r.amount == 0 && !validNet) ||
            (r.amount * 100 - (r.amount * 100).round()).abs() > .000001 ||
            !['expense', 'income'].contains(r.type)) {
          throw const FormatException('账单金额或收支类型无效，请重新预览');
        }
        if (!existing.add(fingerprint(r))) continue;
        final draft = pendingCategories[r.categoryId];
        if (draft != null) {
          if (draft.userId != user.id || draft.type != r.type ||
              draft.name.trim().isEmpty || draft.id == null || draft.id! >= 0) {
            throw const FormatException('待导入分类无效，请重新预览');
          }
          var categoryId = resolvedCategories[draft.id];
          if (categoryId == null) {
            final matching = await txn.query('categories',
              where: 'user_id = ? AND type = ? AND trim(name) = ?',
              whereArgs: [user.id, draft.type, draft.name.trim()], orderBy: 'id', limit: 1);
            categoryId = matching.isNotEmpty ? matching.single['id'] as int
              : await txn.insert('categories', Category(name: draft.name.trim(),
                  type: draft.type, userId: user.id, icon: 'other').toMap()..remove('id'));
            resolvedCategories[draft.id!] = categoryId;
          }
          r = ExpenseRecord.fromMap({...r.toMap(), 'category_id': categoryId});
        }
        final ledger = await txn.query('ledgers', where: 'id = ? AND user_id = ?', whereArgs: [r.ledgerId, r.userId]);
        final category = await txn.query('categories', where: 'id = ? AND type = ? AND user_id = ?', whereArgs: [r.categoryId, r.type, r.userId]);
        if (ledger.isEmpty || category.isEmpty) throw const FormatException('账本或分类已变化，请重新选择文件');
        if (r.assetAccountId != null) {
          final account = await txn.query('asset_accounts', where: 'id = ? AND user_id = ?', whereArgs: [r.assetAccountId, r.userId]);
          if (account.isEmpty) throw const FormatException('账户已变化，请重新选择文件');
        }
        final recordId = await txn.insert('expense_records', r.toMap()..remove('id'));
        if (validNet) {
          await txn.insert('refund_sources', {'user_id': user.id, 'import_key': r.importKey,
            'gross_cents': r.refundGrossCents, 'refund_cents': r.refundTotalCents,
            'basis': 'export', 'record_id': recordId, 'manually_edited': 0,
            'version': 1, 'original_json': jsonEncode({'导入方式': '本软件CSV净额，不重复扣退款'})});
          if (r.amount == 0) fullyRefunded++;
        }
        inserted++;
      }
      for (final plan in refundPlans) {
        final r = plan.record;
        if (r.userId != user.id || r.type != 'expense' || r.importKey != plan.importKey ||
            r.amount != plan.state.netCents / 100 || plan.state.grossCents <= 0 ||
            r.refundGrossCents != plan.state.grossCents ||
            r.refundTotalCents != plan.state.refundedCents || r.refundBasis != plan.state.basis ||
            plan.state.netCents < 0 || plan.state.refundedCents < 0 || plan.state.manuallyEdited ||
            !['none', 'cumulative', 'events', 'export'].contains(plan.state.basis)) {
          throw const FormatException('退款预览数据无效，请重新选择文件');
        }
        final currentRows = await txn.query('expense_records',
          where: 'import_key = ? AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)',
          whereArgs: [plan.importKey, user.id]);
        final currentSource = await txn.query('refund_sources', where: 'user_id = ? AND import_key = ?',
          whereArgs: [user.id, plan.importKey]);
        final currentEvents = await txn.query('refund_events', where: 'user_id = ? AND import_key = ?',
          whereArgs: [user.id, plan.importKey], orderBy: 'id');
        if (currentRows.length > 1 || currentSource.length > 1 ||
            RefundImportPlan.stableMap(currentRows.isEmpty ? null : currentRows.single) != RefundImportPlan.stableMap(plan.expectedRecord) ||
            RefundImportPlan.stableMap(currentSource.isEmpty ? null : currentSource.single) != RefundImportPlan.stableMap(plan.expectedSource) ||
            jsonEncode(currentEvents.map(RefundImportPlan.stableMap).toList()) != jsonEncode(plan.expectedEvents.map(RefundImportPlan.stableMap).toList())) {
          throw const FormatException('预览后账单或退款状态发生变化，请重新选择文件，未导入任何记录');
        }
        final ledger = await txn.query('ledgers', where: 'id = ? AND user_id = ?', whereArgs: [r.ledgerId, user.id]);
        final category = await txn.query('categories', where: 'id = ? AND type = ? AND user_id = ?', whereArgs: [r.categoryId, 'expense', user.id]);
        if (ledger.isEmpty || category.isEmpty) throw const FormatException('账本或分类已变化，请重新预览');
        if (r.assetAccountId != null && (await txn.query('asset_accounts', where: 'id = ? AND user_id = ?', whereArgs: [r.assetAccountId, user.id])).isEmpty) {
          throw const FormatException('原账单账户已变化，请重新预览');
        }
        if (plan.isNew && removedRecordFingerprints(reviewRows, user.id).contains(jsonEncode([user.id, plan.importKey]))) {
          throw const FormatException('原订单已撤销，请重新核对');
        }
        final map = r.toMap()..remove('id');
        final int recordId;
        if (plan.isNew) {
          recordId = await txn.insert('expense_records', map);
          inserted++;
        } else {
          recordId = plan.expectedRecord!['id'] as int;
          await txn.update('expense_records', map, where: 'id = ?', whereArgs: [recordId]);
          updated++;
        }
        final sourceMap = {'user_id': user.id, 'import_key': plan.importKey,
          'gross_cents': plan.state.grossCents, 'refund_cents': plan.state.refundedCents,
          'basis': plan.state.basis, 'snapshot_at': plan.state.snapshotAt?.toIso8601String(),
          'record_id': recordId, 'manually_edited': 0,
          'version': plan.state.version + 1, 'original_json': jsonEncode(plan.original)};
        if (plan.expectedSource == null) {
          await txn.insert('refund_sources', sourceMap);
        } else {
          await txn.update('refund_sources', sourceMap, where: 'id = ?', whereArgs: [plan.expectedSource!['id']]);
        }
        for (final event in plan.eventEvidence) {
          final sameId = await txn.query('refund_events', where: 'user_id = ? AND source = ? AND refund_id = ?',
            whereArgs: [user.id, event.source, event.refundId]);
          if (sameId.isNotEmpty) throw const FormatException('退款单号在预览后已导入或关联其他订单，请重新预览');
          await txn.insert('refund_events', {'user_id': user.id, 'source': event.source,
            'refund_id': event.refundId, 'import_key': event.importKey, 'amount_cents': event.eventCents,
            'refunded_at': event.refundedAt?.toIso8601String(), 'original_json': jsonEncode(event.original)});
        }
        if (plan.fullyRefunded) fullyRefunded++;
      }
      // Confirmed bills and original review rows are committed together.
      // Resolved/ignored rows also retain their key across repeated imports.
      final existingReviews = reviewRows.map((row) => row['row_key'] as String).toSet();
      for (final review in reviewItems) {
        if (review.userId != user.id) throw const FormatException('当前用户已变化，请重新预览账单');
        if (review.rowKey.isEmpty || review.source.isEmpty || review.reason.isEmpty) {
          throw const FormatException('待核对记录信息不完整，请重新选择文件');
        }
        if (!existingReviews.add(review.rowKey)) continue;
        await txn.insert('import_reviews', review.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
        queueChanged = true;
        queued++;
      }
      return BillImportResult(inserted: inserted, updated: updated, fullyRefunded: fullyRefunded, queued: queued);
    });
    if (result.inserted > 0 || result.updated > 0 || queueChanged) billDataRevision.value++;
    return result;
  }
}
