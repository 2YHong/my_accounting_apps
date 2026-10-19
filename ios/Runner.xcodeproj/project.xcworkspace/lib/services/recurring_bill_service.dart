import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/recurring_bill.dart';
import 'bill_csv_service.dart';
import 'recurring_notifications.dart';

class RecurringBillService {
  final DatabaseHelper db;
  RecurringBillService(this.db);

  Future<int> _userId() async {
    final id = (await db.getCurrentUser()).id;
    if (id == null) throw const FormatException('请先选择用户');
    return id;
  }

  DateTime _today(DateTime? now) {
    final date = RecurringBill.dateOnly(now ?? DateTime.now());
    if (date.year < 1900 || date.year > 2200) throw const FormatException('日期超出支持范围');
    return date;
  }

  Future<List<RecurringBill>> getAll({bool includeDeleted = false}) async {
    final userId = await _userId();
    final database = await db.database;
    final rows = await database.query('recurring_bills',
      where: 'user_id = ?${includeDeleted ? '' : ' AND deleted_at IS NULL'}',
      whereArgs: [userId], orderBy: 'enabled DESC, day_of_month ASC, id ASC');
    return rows.map(RecurringBill.fromMap).toList();
  }

  Future<List<RecurringBill>> getEnabled() async =>
    (await getAll()).where((rule) => rule.enabled).toList();

  Future<void> _validateReferences(DatabaseExecutor txn, int userId,
    int ledgerId, int categoryId, int? accountId, String type) async {
    final ledger = await txn.query('ledgers', where: 'id = ? AND user_id = ?',
      whereArgs: [ledgerId, userId], limit: 1);
    final category = await txn.query('categories',
      where: 'id = ? AND user_id = ? AND type = ?',
      whereArgs: [categoryId, userId, type], limit: 1);
    if (ledger.isEmpty || category.isEmpty) {
      throw const FormatException('原账本或分类已删除，请重新选择');
    }
    if (accountId != null) {
      final account = await txn.query('asset_accounts',
        where: 'id = ? AND user_id = ?', whereArgs: [accountId, userId], limit: 1);
      if (account.isEmpty) throw const FormatException('原账户已删除，请重新选择');
    }
  }

  Future<void> _materializeRule(DatabaseExecutor txn, RecurringBill rule,
    DateTime today, String timestamp) async {
    if (!rule.enabled || rule.deletedAt != null || rule.id == null) return;
    final rows = await txn.query('recurring_occurrences', columns: ['period'],
      where: 'rule_id = ? AND user_id = ?', whereArgs: [rule.id, rule.userId]);
    final completedOrPending = rows.map((row) => row['period'] as String).toSet();
    for (final due in rule.datesBetween(rule.activeFrom, today,
      excludedPeriods: completedOrPending)) {
      await txn.insert('recurring_occurrences', {
        'rule_id': rule.id, 'user_id': rule.userId,
        'period': RecurringBill.periodFor(due), 'due_date': due.toIso8601String(),
        'snapshot': jsonEncode(rule.toMap()), 'status': 'pending', 'created_at': timestamp,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _materializeAll(DatabaseExecutor txn, int userId, DateTime today) async {
    final rows = await txn.query('recurring_bills',
      where: 'user_id = ? AND enabled = 1 AND deleted_at IS NULL', whereArgs: [userId]);
    final timestamp = DateTime.now().toIso8601String();
    for (final row in rows) {
      await _materializeRule(txn, RecurringBill.fromMap(row), today, timestamp);
    }
  }

  Future<List<RecurringOccurrence>> getPendingOccurrences({DateTime? now,
    int limit = 100, int offset = 0}) async {
    if (limit < 1 || limit > 500 || offset < 0) throw ArgumentError('无效的分页范围');
    final userId = await _userId();
    final database = await db.database;
    return database.transaction((txn) async {
      await _materializeAll(txn, userId, _today(now));
      final rows = await txn.query('recurring_occurrences',
        where: 'user_id = ? AND status = ?', whereArgs: [userId, 'pending'],
        orderBy: 'due_date ASC, id ASC', limit: limit, offset: offset);
      return rows.map(RecurringOccurrence.fromMap).toList();
    });
  }

  Future<int> getPendingCount({DateTime? now}) async {
    final userId = await _userId();
    final database = await db.database;
    return database.transaction((txn) async {
      await _materializeAll(txn, userId, _today(now));
      return Sqflite.firstIntValue(await txn.rawQuery(
        'SELECT COUNT(*) FROM recurring_occurrences WHERE user_id = ? AND status = ?',
        [userId, 'pending'])) ?? 0;
    });
  }

  /// Returns future periods only. All processed/pending periods are excluded,
  /// including ones whose generated bill was later deleted by the user.
  Future<List<DateTime>> upcomingReminderDates({DateTime? now, int months = 6}) async {
    if (months < 1 || months > 24) throw ArgumentError.value(months, 'months');
    final today = _today(now);
    final userId = await _userId();
    final database = await db.database;
    return database.transaction((txn) async {
      await _materializeAll(txn, userId, today);
      final rules = await txn.query('recurring_bills',
        where: 'user_id = ? AND enabled = 1 AND deleted_at IS NULL', whereArgs: [userId]);
      final occurrences = await txn.query('recurring_occurrences',
        columns: ['rule_id', 'period', 'status', 'due_date'],
        where: 'user_id = ?', whereArgs: [userId]);
      final last = DateTime(today.year, today.month + months + 1, 0);
      final dates = <DateTime>{};
      for (final row in rules) {
        final rule = RecurringBill.fromMap(row);
        final done = occurrences.where((item) => item['rule_id'] == rule.id)
          .map((item) => item['period'] as String).toSet();
        dates.addAll(rule.datesBetween(today, last, excludedPeriods: done));
      }
      // A current-day pending occurrence still needs today's reminder.
      for (final item in occurrences) {
        if (item['status'] == 'pending' && rules.any((rule) => rule['id'] == item['rule_id'])) {
          final due = RecurringBill.dateOnly(DateTime.parse(item['due_date'] as String));
          if (due == today) dates.add(due);
        }
      }
      return dates.toList()..sort();
    });
  }

  Future<int> save(RecurringBill rule, {DateTime? now}) async {
    final today = _today(now);
    if (!['expense', 'income'].contains(rule.type) || rule.title.trim().isEmpty ||
      rule.title.trim().length > 100 || rule.amountCents <= 0 || rule.amountCents > 999999999999 ||
      rule.dayOfMonth < 1 || rule.dayOfMonth > 31 ||
      rule.startDate.year < 1900 || rule.startDate.year > 2200) {
      throw const FormatException('请填写名称、正确金额、开始日期和每月日期');
    }
    final userId = await _userId();
    final database = await db.database;
    final id = await database.transaction((txn) async {
      await _validateReferences(txn, userId, rule.ledgerId, rule.categoryId,
        rule.assetAccountId, rule.type);
      final timestamp = DateTime.now().toIso8601String();
      var activeFrom = today;
      if (rule.id != null) {
        final rows = await txn.query('recurring_bills',
          where: 'id = ? AND user_id = ? AND deleted_at IS NULL',
          whereArgs: [rule.id, userId], limit: 1);
        if (rows.isEmpty) throw const FormatException('此计划已删除，请刷新列表');
        final old = RecurringBill.fromMap(rows.single);
        await _materializeRule(txn, old, today, timestamp);
        activeFrom = old.activeFrom;
        if (!old.enabled && rule.enabled) activeFrom = today;
        if (old.dayOfMonth != rule.dayOfMonth ||
          RecurringBill.dateOnly(old.startDate) != RecurringBill.dateOnly(rule.startDate)) {
          activeFrom = DateTime(today.year, today.month, today.day + 1);
        }
      }
      if (RecurringBill.dateOnly(rule.startDate).isAfter(activeFrom)) {
        activeFrom = RecurringBill.dateOnly(rule.startDate);
      }
      final saved = RecurringBill(id: rule.id, userId: userId,
        title: rule.title.trim(), type: rule.type, amountCents: rule.amountCents,
        ledgerId: rule.ledgerId, categoryId: rule.categoryId,
        assetAccountId: rule.assetAccountId, dayOfMonth: rule.dayOfMonth,
        startDate: rule.startDate, activeFrom: activeFrom,
        enabled: rule.enabled, note: rule.note?.trim());
      final values = saved.toMap()..remove('id');
      values['updated_at'] = timestamp;
      int ruleId;
      if (rule.id == null) {
        values['created_at'] = timestamp;
        ruleId = await txn.insert('recurring_bills', values);
      } else {
        ruleId = rule.id!;
        await txn.update('recurring_bills', values, where: 'id = ? AND user_id = ?',
          whereArgs: [ruleId, userId]);
      }
      final persisted = await txn.query('recurring_bills', where: 'id = ?', whereArgs: [ruleId]);
      await _materializeRule(txn, RecurringBill.fromMap(persisted.single), today, timestamp);
      return ruleId;
    });
    recurringDataRevision.value++;
    return id;
  }

  Future<void> setEnabled(int id, bool enabled, {DateTime? now}) async {
    final today = _today(now);
    final userId = await _userId();
    final database = await db.database;
    await database.transaction((txn) async {
      final rows = await txn.query('recurring_bills',
        where: 'id = ? AND user_id = ? AND deleted_at IS NULL', whereArgs: [id, userId], limit: 1);
      if (rows.isEmpty) throw const FormatException('此计划已删除，请刷新列表');
      final rule = RecurringBill.fromMap(rows.single);
      if (rule.enabled == enabled) return;
      final timestamp = DateTime.now().toIso8601String();
      await _materializeRule(txn, rule, today, timestamp);
      if (enabled) await _validateReferences(txn, userId, rule.ledgerId,
        rule.categoryId, rule.assetAccountId, rule.type);
      await txn.update('recurring_bills', {
        'enabled': enabled ? 1 : 0, 'updated_at': timestamp,
        if (enabled) 'active_from': today.toIso8601String(),
      }, where: 'id = ? AND user_id = ?', whereArgs: [id, userId]);
    });
    recurringDataRevision.value++;
  }

  Future<void> delete(int id, {DateTime? now}) async {
    final today = _today(now);
    final userId = await _userId();
    final database = await db.database;
    await database.transaction((txn) async {
      final rows = await txn.query('recurring_bills',
        where: 'id = ? AND user_id = ? AND deleted_at IS NULL', whereArgs: [id, userId], limit: 1);
      if (rows.isEmpty) return;
      final timestamp = DateTime.now().toIso8601String();
      await _materializeRule(txn, RecurringBill.fromMap(rows.single), today, timestamp);
      await txn.update('recurring_bills', {
        'enabled': 0, 'deleted_at': timestamp, 'updated_at': timestamp,
      }, where: 'id = ? AND user_id = ?', whereArgs: [id, userId]);
      await txn.update('recurring_occurrences', {
        'status': 'skipped', 'resolution': '计划已删除，本期不记账', 'resolved_at': timestamp,
      }, where: 'rule_id = ? AND user_id = ? AND status = ?', whereArgs: [id, userId, 'pending']);
    });
    recurringDataRevision.value++;
  }

  Future<int> confirm(RecurringOccurrence occurrence, ExpenseRecord record) async {
    final userId = await _userId();
    final database = await db.database;
    var created = false;
    final recordId = await database.transaction((txn) async {
      final rows = await txn.query('recurring_occurrences',
        where: 'id = ? AND user_id = ?', whereArgs: [occurrence.id, userId], limit: 1);
      if (rows.isEmpty) throw const FormatException('找不到本期待确认账单');
      final current = RecurringOccurrence.fromMap(rows.single);
      if (current.status == 'confirmed' && current.recordId != null) return current.recordId!;
      if (current.status != 'pending') throw const FormatException('本期已跳过，请刷新列表');
      final amountCents = record.amount.isFinite
        ? RecurringBill.parseAmountCents(record.amount.toStringAsFixed(2)) : null;
      if (!record.amount.isFinite || record.amount <= 0 || record.amount > 9999999999.99 ||
        amountCents == null || (record.amount - amountCents / 100).abs() > .0000001 ||
        !['expense', 'income'].contains(record.type) || (record.title?.trim().isEmpty ?? true) ||
        record.date.year < 1900 || record.date.year > 2200) {
        throw const FormatException('请填写正确的名称、金额和交易日期');
      }
      await _validateReferences(txn, userId, record.ledgerId, record.categoryId,
        record.assetAccountId, record.type);
      record.id = null;
      record.userId = userId;
      record.cloudId = null;
      record.isSynced = 0;
      record.importKey = 'recurring:${current.ruleId}:${current.period}';
      record.title = record.title!.trim();
      final id = await txn.insert('expense_records', record.toMap()..remove('id'));
      await txn.update('recurring_occurrences', {
        'status': 'confirmed', 'record_id': id, 'resolution': jsonEncode(record.toMap()),
        'resolved_at': DateTime.now().toIso8601String(),
      }, where: 'id = ? AND user_id = ? AND status = ?',
        whereArgs: [current.id, userId, 'pending']);
      created = true;
      return id;
    });
    recurringDataRevision.value++;
    if (created) billDataRevision.value++;
    return recordId;
  }

  /// Candidates are suggestions only. The user must choose the matching bill;
  /// same amount and month alone are never used to merge a payment.
  Future<List<ExpenseRecord>> getExistingCandidates(RecurringOccurrence occurrence) async {
    final userId = await _userId();
    final database = await db.database;
    final rows = await database.query('recurring_occurrences',
      where: 'id = ? AND user_id = ? AND status = ?',
      whereArgs: [occurrence.id, userId, 'pending'], limit: 1);
    if (rows.isEmpty) throw const FormatException('本期已处理，请刷新列表');
    final item = RecurringOccurrence.fromMap(rows.single);
    final first = DateTime(item.dueDate.year, item.dueDate.month - 1);
    final last = DateTime(item.dueDate.year, item.dueDate.month + 2);
    final records = await database.query('expense_records',
      where: '''type = ? AND date >= ? AND date < ?
        AND (user_id IS NULL OR user_id = ?)
        AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)
        AND id NOT IN (SELECT record_id FROM recurring_occurrences
          WHERE user_id = ? AND status = 'confirmed' AND record_id IS NOT NULL)''',
      whereArgs: [item.snapshot.type, first.toIso8601String(), last.toIso8601String(),
        userId, userId, userId], orderBy: 'date DESC', limit: 300);
    final result = records.map(ExpenseRecord.fromMap).toList();
    result.sort((left, right) {
      int score(ExpenseRecord record) =>
        (record.title == item.snapshot.title ? 2 : 0) +
        ((record.amount - item.snapshot.amount).abs() < .000001 ? 1 : 0);
      final byMatch = score(right).compareTo(score(left));
      return byMatch != 0 ? byMatch : right.date.compareTo(left.date);
    });
    return result;
  }

  Future<void> linkExisting(RecurringOccurrence occurrence, int recordId) async {
    final userId = await _userId();
    final database = await db.database;
    await database.transaction((txn) async {
      final rows = await txn.query('recurring_occurrences',
        where: 'id = ? AND user_id = ?', whereArgs: [occurrence.id, userId], limit: 1);
      if (rows.isEmpty) throw const FormatException('找不到本期待确认账单');
      final item = RecurringOccurrence.fromMap(rows.single);
      if (item.status == 'confirmed' && item.recordId == recordId) return;
      if (item.status != 'pending') throw const FormatException('本期已经处理，请刷新列表');
      final records = await txn.query('expense_records',
        where: '''id = ? AND type = ? AND (user_id IS NULL OR user_id = ?)
          AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)''',
        whereArgs: [recordId, item.snapshot.type, userId, userId], limit: 1);
      if (records.isEmpty) throw const FormatException('已有账单已变化，请重新选择');
      final linked = await txn.query('recurring_occurrences', columns: ['id'],
        where: 'user_id = ? AND record_id = ? AND status = ?',
        whereArgs: [userId, recordId, 'confirmed'], limit: 1);
      if (linked.isNotEmpty) throw const FormatException('这笔账单已关联其他固定收支期次');
      await txn.update('recurring_occurrences', {
        'status': 'confirmed', 'record_id': recordId,
        'resolution': jsonEncode({'action': 'linked_existing', 'record': records.single}),
        'resolved_at': DateTime.now().toIso8601String(),
      }, where: 'id = ? AND user_id = ? AND status = ?',
        whereArgs: [occurrence.id, userId, 'pending']);
    });
    recurringDataRevision.value++;
  }

  Future<void> skip(RecurringOccurrence occurrence) async {
    final userId = await _userId();
    final database = await db.database;
    await database.transaction((txn) async {
      final rows = await txn.query('recurring_occurrences',
        where: 'id = ? AND user_id = ?', whereArgs: [occurrence.id, userId], limit: 1);
      if (rows.isEmpty) throw const FormatException('找不到本期待确认账单');
      if (rows.single['status'] == 'confirmed') throw const FormatException('本期已经记账');
      if (rows.single['status'] == 'skipped') return;
      await txn.update('recurring_occurrences', {
        'status': 'skipped', 'resolution': '用户跳过本期',
        'resolved_at': DateTime.now().toIso8601String(),
      }, where: 'id = ? AND user_id = ? AND status = ?', whereArgs: [occurrence.id, userId, 'pending']);
    });
    recurringDataRevision.value++;
  }
}
