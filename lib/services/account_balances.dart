import 'package:sqflite/sqflite.dart';

/// Balance is an opening amount plus net linked bills since its checkpoint.
/// Receiving a bill never writes another adjustment, preventing double debit.
class AccountBalances {
  static String netSql(String account) =>
      '''
    COALESCE((SELECT SUM(
      CASE WHEN r.type = 'income' THEN 1 ELSE -1 END *
      CASE WHEN $account.type = 'loan' THEN -1 ELSE 1 END *
      CAST(ROUND(r.amount * 100) AS INTEGER))
    FROM expense_records r LEFT JOIN ledgers l ON l.id = r.ledger_id
    WHERE r.asset_account_id = $account.id
      AND COALESCE(r.user_id, l.user_id) IS $account.user_id), 0)
  ''';

  static Future<List<Map<String, Object?>>> read(
    DatabaseExecutor db, {
    int? userId,
    int? id,
  }) => db.rawQuery(
    '''
    SELECT a.*, CAST(ROUND(a.balance * 100) AS INTEGER) +
      ${netSql('a')} - COALESCE(a.balance_offset_cents, ${netSql('a')})
      AS current_balance_cents
    FROM asset_accounts a
    WHERE ${userId == null ? '1=1' : 'a.user_id = ?'}
      ${id == null ? '' : 'AND a.id = ?'}
    ORDER BY a.type, a.name
  ''',
    [if (userId != null) userId, if (id != null) id],
  );

  static Future<int> net(DatabaseExecutor db, int id) async {
    final rows = await db.rawQuery(
      'SELECT ${netSql('a')} AS net FROM asset_accounts a WHERE a.id = ?',
      [id],
    );
    if (rows.isEmpty) throw StateError('账户不存在，请刷新后重试');
    return (rows.single['net'] as num).toInt();
  }

  /// Runs in the upgrade transaction before any new bill can be written.
  static Future<void> migrate(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE asset_accounts ADD COLUMN balance_offset_cents INTEGER',
    );
    await initializeLegacy(db);
  }

  /// Cloud projection explicitly queues these rows while capture is paused.
  static Future<List<int>> initializeLegacy(
    DatabaseExecutor db, {
    int? userId,
  }) async {
    final rows = await db.query(
      'asset_accounts',
      columns: ['id'],
      where:
          'balance_offset_cents IS NULL${userId == null ? '' : ' AND user_id = ?'}',
      whereArgs: [if (userId != null) userId],
    );
    if (rows.isEmpty) return [];
    await db.rawUpdate(
      '''
      UPDATE asset_accounts SET balance_offset_cents = ${netSql('asset_accounts')}
      WHERE balance_offset_cents IS NULL
      ${userId == null ? '' : 'AND user_id = ?'}
    ''',
      [if (userId != null) userId],
    );
    return rows.map((r) => r['id'] as int).toList();
  }

  /// Changing the displayed amount calibrates it at the current bill net.
  static Future<int> calibrate(
    DatabaseExecutor db,
    int id,
    double amount,
  ) async {
    if (!amount.isFinite) throw ArgumentError('请输入有效的余额');
    return db.rawUpdate(
      '''
      UPDATE asset_accounts
      SET balance = ?, balance_offset_cents = ${netSql('asset_accounts')}
      WHERE id = ?
    ''',
      [(amount * 100).round() / 100, id],
    );
  }

  static int snapshotNet(
    Map<String, Object?> account,
    List<Map<String, Object?>> records,
    List<Map<String, Object?>> ledgers,
  ) {
    final owners = {for (final l in ledgers) l['id']: l['user_id']};
    var cents = 0;
    for (final r in records) {
      if (r['asset_account_id'] != account['id'] ||
          (r['user_id'] ?? owners[r['ledger_id']]) != account['user_id'])
        continue;
      final sign =
          (r['type'] == 'income' ? 1 : -1) *
          (account['type'] == 'loan' ? -1 : 1);
      cents += sign * ((r['amount'] as num) * 100).round();
    }
    return cents;
  }
}
