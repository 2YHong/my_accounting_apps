import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/models/full_backup.dart';
import 'package:my_accounting_app/services/account_balances.dart';
import 'package:my_accounting_app/services/bill_csv_service.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';
import 'package:my_accounting_app/services/named_bill_service.dart';
import 'package:my_accounting_app/sync/cloud_sync_store.dart';
import 'package:my_accounting_app/sync/local_sync_schema.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';
import 'package:my_accounting_app/sync/revision_crypto.dart';
import 'package:my_accounting_app/sync/sync_coordinator.dart';
import 'package:my_accounting_app/sync/sync_protocol.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';
import 'support/sql_bridge.dart';

Future<CloudSyncStore> device(String name, {int offset = 0}) async {
  final db = SqlBridge(
    name,
    Uri.parse(Platform.environment['SQL_BRIDGE_URL']!),
    Platform.environment['SQL_BRIDGE_TOKEN']!,
  );
  addTearDown(db.close);
  final user = offset + 1;
  await db.execute('PRAGMA user_version=10');
  await db.insert('users', {'id': user, 'username': 'test'});
  await db.insert('ledgers', {
    'id': user,
    'user_id': user,
    'name': '总账本',
    'is_default': 1,
  });
  await db.insert('categories', {
    'id': user,
    'user_id': user,
    'name': '餐饮',
    'type': 'expense',
    'is_system': 1,
  });
  await db.insert('categories', {
    'id': user + 1,
    'user_id': user,
    'name': '工资',
    'type': 'income',
    'is_system': 1,
  });
  await LocalSyncSchema.install(db);
  final scope =
      (await db.query('local_sync_control')).single['installation_scope']
          as String;
  return CloudSyncStore(db, scope, user);
}

Future<void> addBill(CloudSyncStore store, String title, double amount) async {
  await store.db.insert(
    'expense_records',
    ExpenseRecord(
      userId: store.user,
      ledgerId: store.user,
      categoryId: store.user,
      type: 'expense',
      amount: amount,
      title: title,
      date: DateTime(2026, 10, 18),
    ).toMap()..remove('id'),
  );
}

class MemoryCloud implements SyncTransport {
  final history = <Map<String, dynamic>>[];
  bool offline = false;
  @override
  String get ownerId => 'test_owner';
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (offline) throw const CloudSyncException('test network unavailable');
    if (path.endsWith('/push')) {
      final wire = Map<String, dynamic>.from(body!['revision'] as Map);
      final old = history
          .where((r) => r['revision_uid'] == wire['revision_uid'])
          .firstOrNull;
      if (old != null) return {'change_seq': old['change_seq']};
      wire['change_seq'] = history.length + 1;
      history.add(wire);
      return {'change_seq': wire['change_seq']};
    }
    if (path.endsWith('/pull')) {
      final after = int.parse(query!['after']!);
      return {
        'protocol': 1,
        'last_seq': history.length,
        'items': history
            .where((r) => (r['change_seq'] as int) > after)
            .take(30)
            .toList(),
      };
    }
    throw StateError('Unexpected endpoint');
  }
}

LocalVault keyFor(String vault, String device) => LocalVault(
  vaultUid: vault,
  deviceUid: device,
  key: SecretKey(List.filled(32, 7)),
  recoveryEnvelope: const {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final enabled = Platform.environment.containsKey('SQL_BRIDGE_URL');

  test(
    'confirm creates categories and imports; repeat is empty; historical account stays unchanged',
    () async {
      final store = await device('named_csv_commit');
      final db = store.db;
      await db.insert('asset_accounts', {
        'id': 1,
        'user_id': 1,
        'name': '现金',
        'type': 'cash',
        'balance': 500.0,
      });
      await AccountBalances.initializeLegacy(db);
      final helper = DatabaseHelper.forTesting(db);
      final input = BillFileReader.read(
        'example.csv',
        utf8.encode(
          '类型,金额,日期,分类,标签,描述,账户\n'
          '支出,12.50,2026/10/18 12:00:00,书籍,,读书,现金\n'
          '收入,20.00,2026/10/18 13:00:00,工资,,,现金\n',
        ),
      ).single;
      final service = NamedBillService(helper);
      final planned = await service.preview(input, ledgerId: 1);
      expect(
        await db.query('categories', where: 'name = ?', whereArgs: ['书籍']),
        isEmpty,
      );
      expect(planned.newCategories.single.name, '书籍');
      final result = await BillCsvService(helper).importPreview(planned);
      expect(result.inserted, 2);
      final records = await db.query('expense_records', orderBy: 'id');
      expect(records.map((r) => r['title']), ['读书', '工资']);
      expect(records.every((r) => (r['category_id'] as int) > 0), isTrue);
      expect(records.every((r) => r['asset_account_id'] == null), isTrue);
      expect(
        (await AccountBalances.read(db, id: 1)).single['current_balance_cents'],
        50000,
      );
      final repeated = await service.preview(input, ledgerId: 1);
      expect(repeated.records, isEmpty);
      expect(repeated.duplicates, 2);
      expect(
        (await BillCsvService(helper).importPreview(repeated)).inserted,
        0,
      );
      expect((await db.query('expense_records')).length, 2);
    },
    skip: !enabled,
  );

  test(
    'failed final validation rolls back both new categories and records',
    () async {
      final store = await device('named_csv_rollback');
      final helper = DatabaseHelper.forTesting(store.db);
      final input = BillFileReader.read(
        'example.csv',
        utf8.encode(
          '类型,金额,日期,分类,标签,描述,账户\n'
          '支出,10,2026/10/18,全新分类,,标题,现金\n',
        ),
      ).single;
      final planned = await NamedBillService(
        helper,
      ).preview(input, ledgerId: 1);
      final categoriesBefore = await store.db.query(
        'categories',
        orderBy: 'id',
      );
      await store.db.delete('ledgers', where: 'id = ?', whereArgs: [1]);
      await expectLater(
        BillCsvService(helper).importPreview(planned),
        throwsA(isA<FormatException>()),
      );
      expect(await store.db.query('expense_records'), isEmpty);
      expect(
        await store.db.query('categories', orderBy: 'id'),
        categoriesBefore,
      );
    },
    skip: !enabled,
  );

  test(
    'joining B with new local bills merges A history and B additions; offline retry preserves both',
    () async {
      final a = await device('sync_preexisting_a');
      final b = await device('sync_preexisting_b', offset: 100);
      final server = MemoryCloud();
      final uid = newSyncId();
      final va = keyFor(uid, newSyncId()), vb = keyFor(uid, newSyncId());
      await a.bind(server.ownerId, uid, va.deviceUid);
      await b.bind(server.ownerId, uid, vb.deviceUid);
      final ea = SyncCoordinator(server, a, va),
          eb = SyncCoordinator(server, b, vb);
      await addBill(a, 'A旧账单', 20);
      await ea.synchronize();
      // B already contains a locally created bill before its very first pull.
      await addBill(b, 'B新增账单', 7);
      await eb.synchronize();
      await ea.synchronize();
      for (final store in [a, b]) {
        final rows = await store.db.query('expense_records');
        expect(rows.length, 2);
        expect(rows.map((r) => r['title']).toSet(), {'A旧账单', 'B新增账单'});
      }
      expect(await ea.conflicts(), isEmpty);
      server.offline = true;
      await addBill(a, '断网期间新增', 3);
      await expectLater(ea.synchronize(), throwsA(isA<CloudSyncException>()));
      expect((await a.db.query('expense_records')).length, 3);
      expect(await a.outgoing((await a.binding())!), isNotEmpty);
      server.offline = false;
      await ea.synchronize();
      await eb.synchronize();
      expect((await b.db.query('expense_records')).length, 3);
      expect(await a.outgoing((await a.binding())!), isEmpty);
    },
    skip: !enabled,
  );

  test(
    'two devices editing the same bill retain their own versions until conflict selection',
    () async {
      final a = await device('sync_conflict_a');
      final b = await device('sync_conflict_b', offset: 100);
      final server = MemoryCloud();
      final uid = newSyncId();
      final va = keyFor(uid, newSyncId()), vb = keyFor(uid, newSyncId());
      await a.bind(server.ownerId, uid, va.deviceUid);
      await b.bind(server.ownerId, uid, vb.deviceUid);
      final ea = SyncCoordinator(server, a, va),
          eb = SyncCoordinator(server, b, vb);
      await addBill(a, '共同账单', 20);
      await ea.synchronize();
      await eb.synchronize();
      await a.db.update(
        'expense_records',
        {'amount': 25.0},
        where: 'title = ?',
        whereArgs: ['共同账单'],
      );
      await b.db.update(
        'expense_records',
        {'amount': 30.0},
        where: 'title = ?',
        whereArgs: ['共同账单'],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      expect((await a.db.query('expense_records')).single['amount'], 25.0);
      expect((await b.db.query('expense_records')).single['amount'], 30.0);
      final conflict = (await ea.conflicts()).single;
      final choice = conflict.choices.indexWhere(
        (p) => (p['values'] as Map)['amount'] == 30.0,
      );
      await ea.resolve(conflict, choice);
      await eb.synchronize();
      expect((await a.db.query('expense_records')).single['amount'], 30.0);
      expect((await b.db.query('expense_records')).single['amount'], 30.0);
    },
    skip: !enabled,
  );

  test(
    'invalid decrypted financial data rolls back projection and leaves capture enabled',
    () async {
      final store = await device('sync_projection_rollback');
      final server = MemoryCloud();
      final vault = keyFor(newSyncId(), newSyncId());
      await store.bind(server.ownerId, vault.vaultUid, vault.deviceUid);
      final engine = SyncCoordinator(server, store, vault);
      await addBill(store, '现有账单', 20);
      await engine.synchronize();
      final before = await store.db.query('expense_records');
      final binding = (await store.binding())!;
      final history = await store.all(binding);
      final meta = (await store.db.query(
        'local_sync_objects',
        where: 'table_name = ?',
        whereArgs: ['expense_records'],
      )).single;
      final head = history.singleWhere(
        (r) => r.objectUid == meta['object_uid'],
      );
      final original = await head.decrypt(
        vault.key,
        server.ownerId,
        vault.vaultUid,
      );
      final payload = {
        ...original,
        'values': {...(original['values'] as Map), 'amount': -9.0},
      };
      final revision = newSyncId();
      final context = RevisionContext(
        ownerId: server.ownerId,
        vaultUid: vault.vaultUid,
        objectUid: head.objectUid,
        revisionUid: revision,
        parentUids: [head.revisionUid],
        keyEpoch: 1,
      );
      final encrypted = await RevisionCrypto().encrypt(
        payload,
        key: vault.key,
        context: context,
      );
      final invalid = EncryptedRevision(
        objectUid: head.objectUid,
        revisionUid: revision,
        parents: [head.revisionUid],
        envelope: encrypted,
      );
      await server.request(
        'POST',
        '/api/accounting/v1/push',
        body: {'revision': invalid.toWire()},
      );
      await expectLater(engine.synchronize(), throwsA(isA<FullBackupException>()));
      expect(await store.db.query('expense_records'), before);
      expect(
        (await store.db.query('local_sync_control')).single['capture_enabled'],
        1,
      );
    },
    skip: !enabled,
  );
}
