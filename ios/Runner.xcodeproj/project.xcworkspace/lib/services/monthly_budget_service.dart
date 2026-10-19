import '../database/database_helper.dart';
import '../models/budget.dart';
import '../models/app_settings.dart';

class MonthlyBudgetService {
  final DatabaseHelper db;
  MonthlyBudgetService(this.db);
  Future<void> save({required int userId, required int ledgerId, int? categoryId,
    required DateTime month, required double amount}) async {
    if (!amount.isFinite || amount <= 0) throw const FormatException('请输入大于0的预算金额');
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 0, 23, 59, 59, 999);
    final database = await db.database;
    await database.transaction((txn) async {
      final ledger = await txn.query('ledgers', where: 'id = ? AND user_id = ?', whereArgs: [ledgerId, userId]);
      if (ledger.isEmpty) throw const FormatException('账本不存在');
      if (categoryId != null) {
        final category = await txn.query('categories', where: 'id = ? AND user_id = ? AND type = ?', whereArgs: [categoryId, userId, 'expense']);
        if (category.isEmpty) throw const FormatException('请选择有效支出分类');
      }
      final existing = await txn.query('budgets', where: 'ledger_id = ? AND cycle = ? AND start_date = ? AND ${categoryId == null ? 'category_id IS NULL' : 'category_id = ?'}',
        whereArgs: [ledgerId, 'month', start.toIso8601String(), if (categoryId != null) categoryId], limit: 1);
      final budget = Budget(id: existing.isEmpty ? null : existing.first['id'] as int,
        ledgerId: ledgerId, categoryId: categoryId, amount: amount, cycle: 'month',
        startDate: start, endDate: end, userId: userId,
        cloudId: existing.isEmpty ? null : existing.first['cloud_id'] as String?);
      if (budget.id == null) { await txn.insert('budgets', budget.toMap()); }
      else { await txn.update('budgets', budget.toMap(), where: 'id = ?', whereArgs: [budget.id]); }
    });
    budgetDataRevision.value++;
  }
}
