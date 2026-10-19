import 'package:my_accounting_app/sync/local_sync_schema.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/models/asset_account.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/models/full_backup.dart';
import 'package:my_accounting_app/services/account_balances.dart';
import 'package:my_accounting_app/services/asset_account_service.dart';
import 'package:my_accounting_app/services/full_backup_service.dart';
import 'support/sql_bridge.dart';

SqlBridge bridge(String id) => SqlBridge(
  id,
  Uri.parse(Platform.environment['SQL_BRIDGE_URL']!),
  Platform.environment['SQL_BRIDGE_TOKEN']!,
);

Future<SqlBridge> fixture(String id) async {
  final db = bridge(id);
  addTearDown(db.close);
  await db.execute('PRAGMA user_version=10');
  await LocalSyncSchema.install(db);
  await db.insert('users', {'id': 1, 'username': 'a'});
  await db.insert('users', {'id': 2, 'username': 'b'});
  await db.insert('ledgers', {'id': 1, 'user_id': 1, 'name': 'book'});
  await db.insert('categories', {
    'id': 1,
    'user_id': 1,
    'name': 'out',
    'type': 'expense',
  });
  await db.insert('categories', {
    'id': 2,
    'user_id': 1,
    'name': 'in',
    'type': 'income',
  });
  return db;
}

ExpenseRecord bill(
  double amount,
  int account, {
  int? id,
  String type = 'expense',
}) => ExpenseRecord(
  id: id,
  ledgerId: 1,
  categoryId: type == 'income' ? 2 : 1,
  userId: 1,
  type: type,
  amount: amount,
  assetAccountId: account,
  date: DateTime(2026, 10, 17),
);

Future<double> amount(SqlBridge db, int id) async =>
    ((await AccountBalances.read(db, id: id)).single['current_balance_cents']
        as int) /
    100;

void main() {
  final enabled = Platform.environment.containsKey('SQL_BRIDGE_URL');
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'preserve legacy balance; new bill edits, moves, deletion, and calibration use cents',
    () async {
      final db = await fixture('balance_operations');
      final helper = DatabaseHelper.forTesting(db);
      final service = AssetAccountService(helper);
      // Simulate a V9 account with a historical linked expense.
      await db.insert('asset_accounts', {
        'id': 1,
        'user_id': 1,
        'name': 'card',
        'type': 'bank',
        'balance': 500.0,
      });
      await db.insert('expense_records', bill(50, 1).toMap()..remove('id'));
      await AccountBalances.initializeLegacy(db);
      expect(await amount(db, 1), 500);
      final other = await service.save(
        AssetAccount(name: 'other', type: 'bank', balance: 1000, userId: 1),
      );
      final id = await helper.insertRecord(bill(50, 1));
      expect(await amount(db, 1), 450);
      final income = await helper.insertRecord(bill(20, 1, type: 'income'));
      expect(await amount(db, 1), 470);
      await helper.updateRecord(bill(60, 1, id: id));
      expect(await amount(db, 1), 460);
      await helper.updateRecord(bill(60, other.id!, id: id));
      expect(await amount(db, 1), 520);
      expect(await amount(db, other.id!), 940);
      await helper.deleteRecord(id);
      expect(await amount(db, other.id!), 1000);
      await helper.deleteRecord(income);
      expect(await amount(db, 1), 500);
      // A stale metadata screen must never reset the current computed amount.
      final stale = (await helper.getAllAssetAccounts(
        userId: 1,
      )).firstWhere((a) => a.id == 1);
      await helper.insertRecord(bill(0.1, 1));
      stale.name = 'renamed';
      await service.save(stale, updateBalance: false);
      expect(await amount(db, 1), 499.9);
      await service.updateBalance(stale, 600);
      expect(await amount(db, 1), 600);
      await helper.insertRecord(bill(0.2, 1));
      expect(await amount(db, 1), 599.8);
      // Another user's invalid legacy reference must never affect this owner.
      await db.insert(
        'expense_records',
        bill(999, 1).toMap()
          ..remove('id')
          ..['user_id'] = 2,
      );
      expect(await amount(db, 1), 599.8);
      expect(await helper.getTotalAssets(userId: 1), 1599.8);
      expect(
        (await db.query('asset_accounts', where: 'id=1')).single['balance'],
        600,
      );
    },
    skip: !enabled,
  );

  test(
    'loan spending increases debt and income reduces it; net refund is counted once',
    () async {
      final db = await fixture('balance_loans');
      final helper = DatabaseHelper.forTesting(db);
      final service = AssetAccountService(helper);
      final loan = await service.save(
        AssetAccount(name: 'loan', type: 'loan', balance: 500, userId: 1),
      );
      final id = await helper.insertRecord(bill(50, loan.id!));
      expect(await helper.getTotalLiabilities(userId: 1), 550);
      await helper.insertRecord(bill(20, loan.id!, type: 'income'));
      expect(await amount(db, loan.id!), 530);
      await db.update(
        'expense_records',
        {
          'amount': 30.0,
          'refund_gross_cents': 5000,
          'refund_total_cents': 2000,
          'refund_basis': 'cumulative',
        },
        where: 'id=?',
        whereArgs: [id],
      );
      expect(await amount(db, loan.id!), 510);
      await db.update(
        'expense_records',
        {'amount': 0.0, 'refund_total_cents': 5000},
        where: 'id=?',
        whereArgs: [id],
      );
      expect(await amount(db, loan.id!), 480);
    },
    skip: !enabled,
  );

  test(
    'V7 encrypted backup upgrades without changing balances; V8 round trip keeps checkpoints',
    () async {
      final db = await fixture('balance_backup');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final helper = DatabaseHelper.forTesting(db);
      final backup = FullBackupService(
        databaseHelper: helper,
        preferences: prefs,
      );
      final service = AssetAccountService(helper);
      final account = await service.save(
        AssetAccount(name: 'card', type: 'bank', balance: 500, userId: 1),
      );
      await helper.insertRecord(bill(50, account.id!));
      final current = await backup.capture();
      expect(current.schemaVersion, 8);
      final bytes = await backup.encrypt(current, 'Local-Test-926584!');
      final opened = await backup.open(bytes, 'Local-Test-926584!');
      await backup.restore(opened);
      expect(await amount(db, account.id!), 450);
      // The same raw 500 in an old archive meant current balance, not opening.
      final tables = {
        ...current.tables,
        'asset_accounts': current.tables['asset_accounts']!
            .map(
              (r) =>
                  Map<String, Object?>.from(r)..remove('balance_offset_cents'),
            )
            .toList(),
      };
      final old = FullBackupSnapshot(
        schemaVersion: 7,
        createdAt: current.createdAt,
        tables: tables,
        settings: current.settings,
        sequences: current.sequences,
      );
      final upgraded = await backup.open(
        await backup.encrypt(old, 'Local-Test-926584!'),
        'Local-Test-926584!',
      );
      expect(upgraded.schemaVersion, 8);
      await backup.restore(upgraded);
      expect(await amount(db, account.id!), 500);
      await helper.insertRecord(bill(50, account.id!));
      expect(await amount(db, account.id!), 450);
      final malformed = {
        ...tables,
        'asset_accounts': tables['asset_accounts']!
            .map((r) => {...r, 'unexpected': true})
            .toList(),
      };
      await expectLater(
        backup.restore(
          FullBackupSnapshot(
            schemaVersion: 7,
            createdAt: old.createdAt,
            tables: malformed,
            settings: old.settings,
            sequences: old.sequences,
          ),
        ),
        throwsA(isA<FullBackupException>()),
      );
      expect(await amount(db, account.id!), 450);
    },
    skip: !enabled,
  );
}
