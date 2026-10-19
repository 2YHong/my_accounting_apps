import '../database/database_helper.dart';
import '../models/asset_account.dart';
import 'asset_notifications.dart';
import 'account_balances.dart';

class DuplicateAssetAccountException implements Exception {
  final AssetAccount existing;
  const DuplicateAssetAccountException(this.existing);
}

/// Account writes use one transaction to prevent double submissions from
/// separate screens and to keep bill references valid when an account is removed.
class AssetAccountService {
  final DatabaseHelper _db;
  AssetAccountService([DatabaseHelper? db]) : _db = db ?? DatabaseHelper();

  Future<AssetAccount> save(
    AssetAccount account, {
    bool updateBalance = true,
  }) async {
    final db = await _db.database;
    final normalizedName = account.name.trim().toLowerCase();
    final id = await db.transaction<int>((txn) async {
      final peers = await txn.query(
        'asset_accounts',
        where: 'user_id IS ? AND type = ?',
        whereArgs: [account.userId, account.type],
      );
      for (final row in peers) {
        if (row['id'] != account.id &&
            (row['name'] as String).trim().toLowerCase() == normalizedName) {
          throw DuplicateAssetAccountException(AssetAccount.fromMap(row));
        }
      }
      final values = account.toMap()..['name'] = account.name.trim();
      if (account.id == null) {
        values.remove('id');
        values['balance'] = (account.balance * 100).round() / 100;
        values['balance_offset_cents'] = 0;
        return txn.insert('asset_accounts', values);
      }
      // Metadata edits never recalibrate against a stale screen balance.
      values.remove('balance');
      values.remove('balance_offset_cents');
      final changed = await txn.update(
        'asset_accounts',
        values,
        where: 'id = ? AND user_id IS ?',
        whereArgs: [account.id, account.userId],
      );
      if (changed != 1) throw StateError('账户不存在，请重新打开账户列表');
      if (updateBalance)
        await AccountBalances.calibrate(txn, account.id!, account.balance);
      return account.id!;
    });
    final saved = AssetAccount.fromMap(
      (await AccountBalances.read(db, id: id)).single,
    );
    notifyAssetAccountsChanged();
    return saved;
  }

  Future<int> linkedBillCount(AssetAccount account) async {
    if (account.id == null) return 0;
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM expense_records WHERE asset_account_id = ?',
      [account.id],
    );
    return (rows.first['total'] as num).toInt();
  }

  Future<void> delete(AssetAccount account) async {
    if (account.id == null) return;
    final db = await _db.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'asset_accounts',
        columns: ['id'],
        where: 'id = ? AND user_id IS ?',
        whereArgs: [account.id, account.userId],
      );
      if (existing.isEmpty) return;
      await txn.update(
        'expense_records',
        {'asset_account_id': null, 'is_synced': 0},
        where: 'asset_account_id = ?',
        whereArgs: [account.id],
      );
      await txn.delete(
        'asset_accounts',
        where: 'id = ? AND user_id IS ?',
        whereArgs: [account.id, account.userId],
      );
    });
    notifyAssetAccountsChanged();
  }

  Future<void> updateBalance(AssetAccount account, double balance) async {
    if (!balance.isFinite || account.id == null) {
      throw ArgumentError('请输入有效的余额');
    }
    final db = await _db.database;
    final changed = await db.transaction((tx) async {
      final owned = await tx.query(
        'asset_accounts',
        columns: ['id'],
        where: 'id = ? AND user_id IS ?',
        whereArgs: [account.id, account.userId],
      );
      if (owned.isEmpty) return 0;
      return AccountBalances.calibrate(tx, account.id!, balance);
    });
    if (changed != 1) throw StateError('账户不存在，请刷新后重试');
    notifyAssetAccountsChanged();
  }
}
