import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/import_review.dart';
import '../models/expense_record.dart';
import 'bill_csv_service.dart';
import 'bill_file_reader.dart';

class ImportReviewService {
  final DatabaseHelper db;
  ImportReviewService(this.db);
  static bool _validOrder(String order) =>
    !['', '/', '-', '--', '—', '不适用'].contains(order) &&
    !order.contains('[数字精度') && !order.contains('[公式单元格') &&
    !RegExp(r'^\d+(?:\.\d+)?[eE][+-]?\d+$').hasMatch(order);

  static String? _originalOrder(ImportReviewItem item, String canonical) {
    final values = item.original.entries
      .where((entry) => BillFileReader.canonicalHeader(entry.key) == canonical)
      .map((entry) => BillFileReader.clean(entry.value))
      .where((value) => value.isNotEmpty).toSet();
    // Conflicting aliases cannot identify a single original payment safely.
    return values.length == 1 && _validOrder(values.single) ? values.single : null;
  }

  static bool _independentRefund(ImportReviewItem item) =>
    item.original.entries.any((entry) =>
      ['原交易号', '退款号'].contains(BillFileReader.canonicalHeader(entry.key)) &&
      BillFileReader.clean(entry.value).isNotEmpty);

  static String? importKeyFor(ImportReviewItem item) {
    // An independent refund's candidate/order can describe the refund itself.
    // Its only safe bill identity is the explicitly linked original payment.
    if (_independentRefund(item)) {
      final original = _originalOrder(item, '原交易号');
      return original == null ? null : '${item.source}:$original';
    }
    final candidateKey = item.candidate?.importKey;
    if (candidateKey?.isNotEmpty ?? false) return candidateKey;
    final namedKey = item.payload['import_key'];
    if (item.source == BillFileReader.namedSource && namedKey is String &&
        RegExp(r'^通用表格:v1:[0-9a-f]{64}:[1-9][0-9]*$').hasMatch(namedKey)) {
      return namedKey;
    }
    final order = _originalOrder(item, '交易号');
    return order == null ? null : '${item.source}:$order';
  }
  Future<ExpenseRecord?> matchingRecord(ImportReviewItem item) async {
    final key = importKeyFor(item);
    if (key == null) return null;
    final user = await db.getCurrentUser();
    final database = await db.database;
    final rows = await database.query('expense_records',
      where: 'import_key = ? AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)',
      whereArgs: [key, user.id], limit: 2);
    if (rows.length > 1) throw const FormatException('此交易号对应多条已有账单，请先在账单页处理重复记录');
    return rows.isEmpty ? null : ExpenseRecord.fromMap(rows.single);
  }
  Future<List<ImportReviewItem>> pending() async {
    final user = await db.getCurrentUser();
    final database = await db.database;
    final rows = await database.query('import_reviews', where: 'user_id = ? AND status = ?',
      whereArgs: [user.id, 'pending'], orderBy: 'id ASC');
    return rows.map(ImportReviewItem.fromMap).toList();
  }
  Future<int> pendingCount() async {
    final user = await db.getCurrentUser();
    final database = await db.database;
    return Sqflite.firstIntValue(await database.rawQuery(
      'SELECT COUNT(*) FROM import_reviews WHERE user_id = ? AND status = ?', [user.id, 'pending'])) ?? 0;
  }
  Future<void> ignore(int id, {int? removeRecordId}) async {
    final user = await db.getCurrentUser();
    final database = await db.database;
    await database.transaction((txn) async {
      final rows = await txn.query('import_reviews', where: 'id = ? AND user_id = ? AND status = ?',
        whereArgs: [id, user.id, 'pending'], limit: 1);
      if (rows.isEmpty) throw const FormatException('这条账单已经处理，请刷新列表');
      final values = <String, Object?>{'status': 'ignored'};
      if (removeRecordId != null) {
        final item = ImportReviewItem.fromMap(rows.single);
        final key = importKeyFor(item);
        final old = await txn.query('expense_records',
          where: 'id = ? AND import_key = ? AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)',
          whereArgs: [removeRecordId, key, user.id], limit: 1);
        if (key == null || old.isEmpty) throw const FormatException('原账单已变化，请重新核对');
        item.payload['previous_record'] = old.single;
        values['payload'] = jsonEncode(item.payload);
        await txn.rawUpdate('UPDATE refund_sources SET record_id = NULL, '
          'manually_edited = 1, version = version + 1 WHERE user_id = ? AND record_id = ?',
          [user.id, removeRecordId]);
        await txn.delete('record_tags', where: 'record_id = ?', whereArgs: [removeRecordId]);
        await txn.delete('expense_records', where: 'id = ?', whereArgs: [removeRecordId]);
      }
      await txn.update('import_reviews', values, where: 'id = ? AND user_id = ?', whereArgs: [id, user.id]);
    });
    if (removeRecordId != null) billDataRevision.value++;
  }
  Future<void> confirm(int id, ExpenseRecord record, {int? existingRecordId}) async {
    if (!record.amount.isFinite || record.amount <= 0 ||
      (record.amount * 100 - (record.amount * 100).round()).abs() > .000001) {
      throw const FormatException('请输入大于0的实际金额，最多两位小数；零金额请标记不计收支');
    }
    if (!['expense', 'income'].contains(record.type)) throw const FormatException('请选择收支类型');
    if (record.date.year < 1900 || record.date.year > 2200) throw const FormatException('请选择1900年至2200年之间的交易日期');
    final user = await db.getCurrentUser();
    final database = await db.database;
    await database.transaction((txn) async {
      final review = await txn.query('import_reviews', where: 'id = ? AND user_id = ? AND status = ?',
        whereArgs: [id, user.id, 'pending'], limit: 1);
      if (review.isEmpty) throw const FormatException('这条账单已经处理，请刷新列表');
      final item = ImportReviewItem.fromMap(review.single);
      final key = importKeyFor(item);
      final independentRefund = _independentRefund(item);
      if (independentRefund && (key == null || existingRecordId == null)) {
        throw const FormatException('独立退款需要核对对应的原支出，请先导入原付款账单，再更新实际净支出；不能将退款另记为收入或新账单');
      }
      if (independentRefund && (record.type != 'expense' || record.importKey != key)) {
        throw const FormatException('请更新原支出的实际净额，不要将同一退款重复记为收入');
      }
      final ledger = await txn.query('ledgers', where: 'id = ? AND user_id = ?', whereArgs: [record.ledgerId, user.id], limit: 1);
      final category = await txn.query('categories', where: 'id = ? AND user_id = ? AND type = ?',
        whereArgs: [record.categoryId, user.id, record.type], limit: 1);
      if (ledger.isEmpty || category.isEmpty) throw const FormatException('账本或分类不存在，请重新选择');
      if (record.assetAccountId != null) {
        final account = await txn.query('asset_accounts', where: 'id = ? AND user_id = ?', whereArgs: [record.assetAccountId, user.id], limit: 1);
        if (account.isEmpty) throw const FormatException('账户不存在，请重新选择');
      }
      record.userId = user.id;
      final refundSources = key == null ? const <Map<String, Object?>>[]
        : await txn.query('refund_sources', where: 'user_id = ? AND import_key = ?',
          whereArgs: [user.id, key]);
      if (refundSources.any((source) => source['record_id'] == null)) {
        throw const FormatException('原账单已撤销或删除，不能通过退款核对重新记账；请将此项标记为不重复记账');
      }
      final previousReviews = await txn.query('import_reviews',
        where: 'user_id = ? AND status = ?', whereArgs: [user.id, 'ignored']);
      if (BillCsvService.removedRecordFingerprints(previousReviews, user.id).contains(BillCsvService.fingerprint(record))) {
        throw const FormatException('该交易已核对为全额退款并撤销，不能再次重复记账；请将此项标记为不重复记账');
      }
      final rows = await txn.query('expense_records',
        where: 'ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)', whereArgs: [user.id]);
      final duplicate = rows.where((r) => r['id'] != existingRecordId).map((r) => BillCsvService.fingerprintForUser(ExpenseRecord.fromMap(r), user.id))
        .contains(BillCsvService.fingerprint(record));
      if (duplicate) throw const FormatException('该交易已经记账，请重新打开本项，核对并更新已有账单');
      int recordId;
      final values = <String, Object?>{'status': 'resolved'};
      if (existingRecordId != null) {
        final old = rows.where((r) => r['id'] == existingRecordId && key != null && r['import_key'] == key).toList();
        if (old.length != 1 || record.importKey != key) throw const FormatException('原账单已变化，请重新核对');
        if (independentRefund && old.single['type'] != 'expense') {
          throw const FormatException('退款对应的原账单不是支出，请先核对原付款账单');
        }
        if (refundSources.any((source) => source['record_id'] != existingRecordId)) {
          throw const FormatException('原账单与退款历史关联已变化，请重新核对');
        }
        item.payload['previous_record'] = old.single;
        values['payload'] = jsonEncode(item.payload);
        recordId = existingRecordId;
        record.id = recordId;
        record.cloudId = old.single['cloud_id'] as String?;
        record.isSynced = 0;
        record.refundGrossCents = old.single['refund_gross_cents'] as int?;
        record.refundTotalCents = old.single['refund_total_cents'] as int?;
        record.refundBasis = old.single['refund_basis'] as String?;
        if (old.single['amount'] != record.amount || old.single['type'] != record.type) {
          await txn.rawUpdate('UPDATE refund_sources SET manually_edited = 1, '
            'version = version + 1 WHERE user_id = ? AND record_id = ?',
            [user.id, recordId]);
        }
        await txn.update('expense_records', record.toMap(), where: 'id = ?', whereArgs: [recordId]);
      } else {
        recordId = await txn.insert('expense_records', record.toMap()..remove('id'));
      }
      values['record_id'] = recordId;
      await txn.update('import_reviews', values,
        where: 'id = ? AND user_id = ?', whereArgs: [id, user.id]);
    });
    billDataRevision.value++;
  }
}
