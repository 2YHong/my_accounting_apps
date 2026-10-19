import 'package:my_accounting_app/services/account_balances.dart';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/full_backup.dart';
import 'package:my_accounting_app/sync/cloud_sync_store.dart';
import 'package:my_accounting_app/sync/local_sync_schema.dart';
import 'package:my_accounting_app/sync/revision_crypto.dart';
import 'support/sql_bridge.dart';

SqlBridge bridge(String id) => SqlBridge(
  id,
  Uri.parse(Platform.environment['SQL_BRIDGE_URL']!),
  Platform.environment['SQL_BRIDGE_TOKEN']!,
);

Future<List<int>> businessHash(SqlBridge db) async {
  final data = <String, Object?>{};
  for (final table in FullBackupValidator.tableOrder) {
    data[table] = await db.query(table);
  }
  return (await Sha256().hash(utf8.encode(jsonEncode(data)))).bytes;
}

void main() {
  final enabled = Platform.environment.containsKey('SQL_BRIDGE_URL');
  test(
    'actual legacy local snapshot freezes without changing any business row',
    () async {
      final db = bridge('legacy_snapshot');
      addTearDown(db.close);
      final accountsBefore = await db.query('asset_accounts');
      final columns = await db.rawQuery('PRAGMA table_info(asset_accounts)');
      if (!columns.any((r) => r['name'] == 'balance_offset_cents')) {
        await db.transaction((tx) => AccountBalances.migrate(tx));
      }
      final accountsAfter = await AccountBalances.read(db);
      expect(
        {for (final a in accountsAfter) a['id']: a['current_balance_cents']},
        {
          for (final a in accountsBefore)
            a['id']: ((a['balance'] as num) * 100).round(),
        },
        reason: 'Upgrading a real snapshot must preserve every current balance',
      );
      final user =
          (await db.query(
                'users',
                columns: ['id'],
                orderBy: 'id',
                limit: 1,
              )).single['id']
              as int;
      final scope =
          (await db.query('local_sync_control')).single['installation_scope']
              as String;
      final s = CloudSyncStore(db, scope, user);
      final before = await businessHash(db);
      final changes = await s.freeze();
      final tombstones = changes
          .where((c) => c.payload['deleted'] == true)
          .length;
      expect(tombstones, greaterThan(0));
      expect(
        await businessHash(db),
        before,
        reason: 'Existing business records stay byte-for-byte equivalent',
      );
      final again = await s.freeze();
      expect(
        again.map((c) => c.objectUid).toSet(),
        changes.map((c) => c.objectUid).toSet(),
      );
      expect(await businessHash(db), before);
    },
    skip:
        !enabled ||
        !Platform.environment.containsKey('ACCOUNTING_LEGACY_FIXTURE'),
  );

  test('historical reference never claims another local user record', () async {
    final db = bridge('legacy_other_owner');
    addTearDown(db.close);
    await db.insert('users', {'id': 1, 'username': 'a'});
    await db.insert('users', {'id': 2, 'username': 'b'});
    await db.insert('ledgers', {'id': 1, 'user_id': 1, 'name': 'ledger'});
    await db.insert('categories', {
      'id': 9,
      'user_id': 2,
      'name': 'other',
      'type': 'expense',
    });
    await db.insert('import_reviews', {
      'user_id': 1,
      'source': 'test',
      'row_key': 'different-owner',
      'reason': 'test',
      'status': 'resolved',
      'created_at': '2026-10-17T00:00:00',
      'payload': jsonEncode({
        'file_name': 'test',
        'original': {},
        'ledger_id': 1,
        'expense_category_id': 9,
        'income_category_id': null,
      }),
    });
    for (final sql in [
      ...LocalSyncSchema.createStatements,
      ...LocalSyncSchema.backfillStatements,
    ]) {
      await db.execute(sql);
    }
    final scope =
        (await db.query('local_sync_control')).single['installation_scope']
            as String;
    final before = await businessHash(db);
    final s = CloudSyncStore(db, scope, 1);
    await expectLater(s.freeze(), throwsA(isA<SyncCryptoException>()));
    expect(await businessHash(db), before);
    final meta = (await db.query(
      'local_sync_objects',
      where: 'table_name=? AND local_key=?',
      whereArgs: ['categories', '9'],
    )).single;
    expect(meta['owner_user_id'], 2);
    expect(meta['deleted'], 0);
  }, skip: !enabled);
}
