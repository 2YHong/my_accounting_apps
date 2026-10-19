import 'package:my_accounting_app/services/account_balances.dart';
import 'package:my_accounting_app/sync/sync_edit_guard.dart';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';
import 'package:my_accounting_app/sync/cloud_sync_store.dart';
import 'package:my_accounting_app/sync/local_sync_schema.dart';
import 'package:my_accounting_app/sync/sync_coordinator.dart';
import 'package:my_accounting_app/sync/sync_protocol.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';
import 'package:my_accounting_app/sync/revision_crypto.dart';
import 'support/sql_bridge.dart';

class Secrets implements VaultSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class Intercept implements SyncTransport {
  final PocketBaseApi api;
  bool loseReply = false;
  Future<void> Function()? editAfterPush;
  Intercept(this.api);
  @override
  String? get ownerId => api.ownerId;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final response = await api.request(method, path, body: body, query: query);
    if (path.endsWith('/push')) {
      final edit = editAfterPush;
      editAfterPush = null;
      if (edit != null) await edit();
      if (loseReply) {
        loseReply = false;
        throw const CloudSyncException('simulated lost response');
      }
    }
    return response;
  }
}

Future<CloudSyncStore> store(
  String id,
  int user,
  int ledger,
  int expenseCategory,
  int incomeCategory,
) async {
  final db = SqlBridge(
    id,
    Uri.parse(Platform.environment['SQL_BRIDGE_URL']!),
    Platform.environment['SQL_BRIDGE_TOKEN']!,
  );
  await db.insert('users', {'id': user, 'username': 'Local $id'});
  await db.insert('ledgers', {
    'id': ledger,
    'name': '总账本',
    'is_default': 1,
    'user_id': user,
  });
  await db.insert('categories', {
    'id': expenseCategory,
    'name': '餐饮',
    'type': 'expense',
    'is_system': 1,
    'user_id': user,
  });
  await db.insert('categories', {
    'id': incomeCategory,
    'name': '工资',
    'type': 'income',
    'is_system': 1,
    'user_id': user,
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
  return CloudSyncStore(db, scope, user);
}

Future<String> pub() async => base64Encode(
  (await (await X25519().newKeyPair()).extractPublicKey()).bytes,
);
Future<Map<String, Object?>> expense(CloudSyncStore s) =>
    s.db.query('expense_records').then((r) => r.single);

void main() {
  final enabled = Platform.environment.containsKey('PB_TEST_URL');
  test(
    'real PocketBase + two native SQLite devices: encrypted recovery, merge, conflicts, retry and pagination',
    () async {
      final url = Platform.environment['PB_TEST_URL']!;
      final a = PocketBaseApi(url: url, storage: Secrets()),
          b = PocketBaseApi(url: url, storage: Secrets());
      final email = 'sync-${newSyncId()}@example.invalid',
          password = 'Local-Test-Only-926584!';
      await a.register(email, password);
      await b.login(email, password);
      expect(a.ownerId, b.ownerId);
      final setup = await VaultKeyStore(storage: Secrets()).prepare(),
          vaultA = setup.vault;
      await a.request(
        'POST',
        '/api/accounting/v1/initialize',
        body: {
          'vault_uid': vaultA.vaultUid,
          'device_uid': vaultA.deviceUid,
          'public_key': await pub(),
          'recovery': vaultA.recoveryEnvelope,
        },
      );
      final remote = await b.request('GET', '/api/accounting/v1/vault');
      final recovery = Map<String, dynamic>.from(remote['recovery'] as Map);
      await expectLater(
        RecoveryCrypto.unwrap(recovery, await RecoveryCrypto.newCode()),
        throwsA(isA<SyncCryptoException>()),
      );
      final keyB = await RecoveryCrypto.unwrap(recovery, setup.recoveryCode);
      expect(await keyB.extractBytes(), await vaultA.key.extractBytes());
      final vaultB = LocalVault(
        vaultUid: vaultA.vaultUid,
        deviceUid: newSyncId(),
        key: keyB,
        recoveryEnvelope: recovery,
      );
      await b.request(
        'POST',
        '/api/accounting/v1/device',
        body: {
          'vault_uid': vaultB.vaultUid,
          'device_uid': vaultB.deviceUid,
          'public_key': await pub(),
        },
      );
      final sa = await store('device_a', 1, 1, 1, 2),
          sb = await store('device_b', 5, 40, 70, 90);
      addTearDown(sa.db.close);
      addTearDown(sb.db.close);
      await sa.bind(a.ownerId!, vaultA.vaultUid, vaultA.deviceUid);
      await sb.bind(b.ownerId!, vaultB.vaultUid, vaultB.deviceUid);
      final transportA = Intercept(a), transportB = Intercept(b);
      final ea = SyncCoordinator(transportA, sa, vaultA),
          eb = SyncCoordinator(transportB, sb, vaultB);
      await sa.db.insert('expense_records', {
        'ledger_id': 1,
        'category_id': 1,
        'type': 'expense',
        'amount': 20.5,
        'date': '2026-10-16T12:00:00',
        'note': '秘密午餐',
        'user_id': 1,
      });
      await ea.synchronize();
      await eb.synchronize();
      expect((await expense(sb))['amount'], 20.5);
      expect((await expense(sb))['ledger_id'], 40);
      expect((await expense(sb))['category_id'], 70);
      expect((await expense(sb))['user_id'], 5);
      final wire = await a.request(
        'GET',
        '/api/accounting/v1/pull',
        query: {
          'vault_uid': vaultA.vaultUid,
          'device_uid': vaultA.deviceUid,
          'after': '0',
          'limit': '30',
        },
      );
      expect(jsonEncode(wire), isNot(contains('秘密午餐')));
      expect(jsonEncode(wire), isNot(contains('amount')));
      expect(jsonEncode(wire), isNot(contains(setup.recoveryCode)));

      // Both offline edits descend from the same revision, rather than one silently
      // becoming a child of a remote edit which the user never saw.
      await sa.db.update(
        'expense_records',
        {'amount': 30.0},
        where: 'id=?',
        whereArgs: [1],
      );
      await sb.db.update(
        'expense_records',
        {'amount': 40.0},
        where: 'id=?',
        whereArgs: [1],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      var conflicts = await ea.conflicts();
      expect(conflicts.length, 1);
      final index = conflicts.single.choices.indexWhere(
        (p) => (p['values'] as Map?)?['amount'] == 40.0,
      );
      expect(index, greaterThanOrEqualTo(0));
      await ea.resolve(conflicts.single, index);
      await eb.synchronize();
      expect((await expense(sa))['amount'], 40.0);
      expect((await expense(sb))['amount'], 40.0);
      expect(await ea.conflicts(), isEmpty);

      // Edit/delete conflict can restore the selected edit on the deleting device.
      await sa.db.delete('expense_records', where: 'id=?', whereArgs: [1]);
      await sb.db.update(
        'expense_records',
        {'note': '保留这次编辑'},
        where: 'id=?',
        whereArgs: [1],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      conflicts = await ea.conflicts();
      expect(conflicts.length, 1);
      final edited = conflicts.single.choices.indexWhere(
        (p) => p['deleted'] == false,
      );
      expect(conflicts.single.choices.any((p) => p['deleted'] == true), true);
      await ea.resolve(conflicts.single, edited);
      await eb.synchronize();
      expect((await expense(sa))['note'], '保留这次编辑');
      expect((await expense(sb))['note'], '保留这次编辑');

      // Choosing deletion must converge too, and later explicit restoration is a
      // new revision rather than removal of the original conflict history.
      await sa.db.delete('expense_records', where: 'id=?', whereArgs: [1]);
      await sb.db.update(
        'expense_records',
        {'amount': 41.0},
        where: 'id=?',
        whereArgs: [1],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      conflicts = await ea.conflicts();
      await ea.resolve(
        conflicts.single,
        conflicts.single.choices.indexWhere((p) => p['deleted'] == true),
      );
      await eb.synchronize();
      expect(await sa.db.query('expense_records'), isEmpty);
      expect(await sb.db.query('expense_records'), isEmpty);
      await sa.db.insert('expense_records', {
        'id': 1,
        'ledger_id': 1,
        'category_id': 1,
        'type': 'expense',
        'amount': 40.0,
        'date': '2026-10-16T12:00:00',
        'note': '显式恢复',
        'user_id': 1,
      });
      await ea.synchronize();
      await eb.synchronize();

      // A response lost after server commit reuses the exact durable ciphertext.
      await sa.db.update(
        'expense_records',
        {'note': '只上传一次'},
        where: 'id=?',
        whereArgs: [1],
      );
      transportA.loseReply = true;
      await expectLater(ea.synchronize(), throwsA(isA<CloudSyncException>()));
      final pending = await sa.outgoing((await sa.binding())!);
      expect(pending.length, 1);
      final pendingId = pending.single.revisionUid;
      final before =
          (await a.request('GET', '/api/accounting/v1/vault'))['vault'] as Map;
      await ea.synchronize();
      final after =
          (await a.request('GET', '/api/accounting/v1/vault'))['vault'] as Map;
      expect(after['last_seq'], before['last_seq']);
      expect(
        (await sa.all(
          (await sa.binding())!,
        )).where((r) => r.revisionUid == pendingId).length,
        1,
      );

      // New edits while an older upload is in flight remain dirty and visible.
      await sa.db.update(
        'expense_records',
        {'note': '上传中的旧值'},
        where: 'id=?',
        whereArgs: [1],
      );
      transportA.editAfterPush = () => sa.db
          .update(
            'expense_records',
            {'note': '上传期间的新值'},
            where: 'id=?',
            whereArgs: [1],
          )
          .then((_) {});
      await ea.synchronize();
      expect((await expense(sa))['note'], '上传期间的新值');
      expect(await sa.freeze(), isNotEmpty);
      await ea.synchronize();
      expect(await sa.freeze(), isEmpty);
      await eb.synchronize();
      expect((await expense(sb))['note'], '上传期间的新值');

      // More than one pull page, with references reconstructed only after caching.
      for (var i = 0; i < 35; i++) {
        final object = newSyncId(), revision = newSyncId();
        final ctx = RevisionContext(
          ownerId: a.ownerId!,
          vaultUid: vaultA.vaultUid,
          objectUid: object,
          revisionUid: revision,
          parentUids: [],
          keyEpoch: 1,
        );
        final envelope = await RevisionCrypto().encrypt(
          {
            'schema': 1,
            'entity': 'tags',
            'deleted': false,
            'values': {'name': '分页标签 $i', 'color': null},
            'links': {},
          },
          key: vaultA.key,
          context: ctx,
        );
        await a.request(
          'POST',
          '/api/accounting/v1/push',
          body: {
            'vault_uid': vaultA.vaultUid,
            'device_uid': vaultA.deviceUid,
            'revision': EncryptedRevision(
              objectUid: object,
              revisionUid: revision,
              parents: [],
              envelope: envelope,
            ).toWire(),
          },
        );
      }
      await eb.synchronize();
      expect((await sb.db.query('tags')).length, 35);

      // A form opened on the older state must create a branch after saving.
      await sb.db.update(
        'expense_records',
        {'amount': 41.0},
        where: 'id=?',
        whereArgs: [(await expense(sb))['id']],
      );
      await eb.synchronize();
      final releaseEditor = SyncEditGuard.acquire();
      final prior = (await expense(sa))['amount'];
      try {
        await ea.synchronize();
        expect((await expense(sa))['amount'], prior);
        expect(ea.deferredObjects, greaterThan(0));
        await sa.db.update(
          'expense_records',
          {'amount': 42.0},
          where: 'id=?',
          whereArgs: [(await expense(sa))['id']],
        );
      } finally {
        releaseEditor();
        releaseEditor(); // Releasing the same route twice cannot unlock another.
      }
      await ea.synchronize();
      final editorConflict = (await ea.conflicts()).single;
      expect(
        editorConflict.choices.map((p) => (p['values'] as Map)['amount']),
        containsAll([41.0, 42.0]),
      );
      await ea.resolve(
        editorConflict,
        editorConflict.choices.indexWhere(
          (p) => (p['values'] as Map)['amount'] == 42.0,
        ),
      );
      await eb.synchronize();
      expect((await expense(sb))['amount'], 42.0);

      // Independently importing one platform transaction is one opaque identity,
      // so an explicit conflict is shown instead of a duplicate-key dead end.
      await sa.db.insert('expense_records', {
        'ledger_id': 1,
        'category_id': 1,
        'type': 'expense',
        'amount': 10.0,
        'date': '2026-10-16T12:00:00',
        'import_key': 'wechat:same-order',
        'user_id': 1,
      });
      await sb.db.insert('expense_records', {
        'ledger_id': 40,
        'category_id': 70,
        'type': 'expense',
        'amount': 11.0,
        'date': '2026-10-16T12:00:00',
        'import_key': 'wechat:same-order',
        'user_id': 5,
      });
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      final imported = (await ea.conflicts())
          .where(
            (c) => c.choices.any(
              (p) =>
                  (p['values'] as Map?)?['import_key'] == 'wechat:same-order',
            ),
          )
          .single;
      final keep = imported.choices.indexWhere(
        (p) => (p['values'] as Map?)?['amount'] == 11.0,
      );
      await ea.resolve(imported, keep);
      await eb.synchronize();
      expect(
        (await sa.db.query(
          'expense_records',
          where: 'import_key=?',
          whereArgs: ['wechat:same-order'],
        )).single['amount'],
        11.0,
      );
      expect(
        (await sb.db.query(
          'expense_records',
          where: 'import_key=?',
          whereArgs: ['wechat:same-order'],
        )).single['amount'],
        11.0,
      );

      // Embedded recurring snapshots must use the receiving device's references.
      final rule = {
        'id': 10,
        'user_id': 1,
        'title': '月度房租',
        'type': 'expense',
        'amount_cents': 10000,
        'ledger_id': 1,
        'category_id': 1,
        'asset_account_id': null,
        'day_of_month': 16,
        'start_date': '2026-10-16T00:00:00',
        'active_from': '2026-10-16T00:00:00',
        'enabled': 1,
        'note': null,
        'deleted_at': null,
      };
      await sa.db.insert('recurring_bills', {
        ...rule,
        'created_at': '2026-10-16T00:00:00',
        'updated_at': '2026-10-16T00:00:00',
      });
      await sa.db.insert('recurring_occurrences', {
        'rule_id': 10,
        'user_id': 1,
        'period': '2026-10',
        'due_date': '2026-10-16T00:00:00',
        'snapshot': jsonEncode(rule),
        'status': 'pending',
        'created_at': '2026-10-16T00:00:00',
      });
      await ea.synchronize();
      await eb.synchronize();
      final rb = (await sb.db.query('recurring_bills')).single,
          occ = (await sb.db.query('recurring_occurrences')).single;
      expect(rb['id'], isNot(10));
      final record = <String, Object?>{
        'user_id': 5,
        'title': '月度房租',
        'type': 'expense',
        'amount': 100.0,
        'ledger_id': 40,
        'category_id': 70,
        'asset_account_id': null,
        'date': '2026-10-16T12:00:00',
        'note': null,
        'import_key': 'recurring:${rb['id']}:2026-10',
      };
      await sb.db.transaction((tx) async {
        final id = await tx.insert('expense_records', record);
        await tx.update(
          'recurring_occurrences',
          {
            'status': 'confirmed',
            'record_id': id,
            'resolution': jsonEncode(record),
            'resolved_at': '2026-10-16T12:00:00',
          },
          where: 'id=?',
          whereArgs: [occ['id']],
        );
      });
      await eb.synchronize();
      await ea.synchronize();
      final restored = (await sa.db.query(
        'expense_records',
        where: 'import_key=?',
        whereArgs: ['recurring:10:2026-10'],
      )).single;
      final resolved = (await sa.db.query('recurring_occurrences')).single;
      expect(resolved['record_id'], restored['id']);
      final snapshot = jsonDecode(resolved['resolution'] as String) as Map;
      expect(snapshot['ledger_id'], 1);
      expect(snapshot['category_id'], 1);

      // Historical references to bills deleted before sync metadata existed are
      // tombstones, with no restored financial records on either device.
      final beforeHistoryCount = (await sa.db.query('expense_records')).length;
      final historyRecord = {
        'type': 'expense',
        'amount': 1.0,
        'ledger_id': 1,
        'category_id': 1,
        'asset_account_id': 70002,
        'date': '2026-10-17T00:00:00',
      };
      await sa.db.insert('import_reviews', {
        'user_id': 1,
        'source': 'test',
        'row_key': 'legacy-deleted',
        'reason': 'history',
        'status': 'resolved',
        'record_id': 70001,
        'created_at': '2026-10-17T00:00:00',
        'payload': jsonEncode({
          'file_name': 'test',
          'original': {},
          'candidate': historyRecord,
          'ledger_id': 1,
          'account_id': 70002,
          'expense_category_id': 1,
          'income_category_id': 2,
        }),
      });
      await sa.db.insert('recurring_occurrences', {
        'rule_id': 10,
        'user_id': 1,
        'period': '2026-11',
        'due_date': '2026-11-16T00:00:00',
        'snapshot': jsonEncode(rule),
        'status': 'confirmed',
        'record_id': 70003,
        'created_at': '2026-11-16T00:00:00',
        'resolved_at': '2026-11-16T12:00:00',
        'resolution': jsonEncode(historyRecord),
      });
      await ea.synchronize();
      await eb.synchronize();
      expect(ea.deferredObjects, 0);
      expect(eb.deferredObjects, 0);
      expect((await sa.db.query('expense_records')).length, beforeHistoryCount);
      expect((await sb.db.query('expense_records')).length, beforeHistoryCount);
      final legacyReview = (await sb.db.query('import_reviews')).single;
      expect(legacyReview['status'], 'resolved');
      final missingBill = legacyReview['record_id'] as int;
      expect(
        await sb.db.query(
          'expense_records',
          where: 'id=?',
          whereArgs: [missingBill],
        ),
        isEmpty,
      );
      final receivedPayload =
          jsonDecode(legacyReview['payload'] as String) as Map;
      expect(
        await sb.db.query(
          'asset_accounts',
          where: 'id=?',
          whereArgs: [receivedPayload['account_id']],
        ),
        isEmpty,
      );
      final reserved =
          (await sb.db.rawQuery(
                "SELECT MAX(CAST(local_key AS INTEGER)) AS value FROM local_sync_objects WHERE table_name='expense_records'",
              )).single['value']
              as int;
      final futureId = await sb.db.insert('expense_records', {
        'user_id': 5,
        'type': 'expense',
        'amount': 2.0,
        'ledger_id': 40,
        'category_id': 70,
        'date': '2026-10-17T12:00:00',
      });
      expect(futureId, greaterThan(reserved));
      await eb.synchronize();
      await ea.synchronize();
      expect(ea.deferredObjects, 0);
      expect(eb.deferredObjects, 0);

      // Invalid ownership and parents cannot consume a sequence or modify history.
      final outsider = PocketBaseApi(url: url, storage: Secrets());
      await outsider.register('other-${newSyncId()}@example.invalid', password);
      await expectLater(
        outsider.request(
          'GET',
          '/api/accounting/v1/pull',
          query: {
            'vault_uid': vaultA.vaultUid,
            'device_uid': vaultA.deviceUid,
            'after': '0',
          },
        ),
        throwsA(isA<CloudSyncException>()),
      );
      await expectLater(
        sa.bind(outsider.ownerId!, 'other_vault', 'other_device'),
        throwsA(isA<SyncCryptoException>()),
      );
      await expectLater(
        a.request('GET', '/api/collections/sync_revisions/records'),
        throwsA(isA<CloudSyncException>()),
      );
      final oldSeq =
          ((await a.request('GET', '/api/accounting/v1/vault'))['vault']
              as Map)['last_seq'];
      final invalid = (await sa.all((await sa.binding())!)).last.toWire();
      invalid['revision_uid'] = newSyncId();
      invalid['parent_uids'] = ['unknown_parent'];
      await expectLater(
        a.request(
          'POST',
          '/api/accounting/v1/push',
          body: {
            'vault_uid': vaultA.vaultUid,
            'device_uid': vaultA.deviceUid,
            'revision': invalid,
          },
        ),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        ((await a.request('GET', '/api/accounting/v1/vault'))['vault']
            as Map)['last_seq'],
        oldSeq,
      );

      // Account balance checkpoints travel inside ciphertext. Old accounts keep
      // their pre-upgrade amount even though a historical linked bill exists.
      final cardA = await sa.db.insert('asset_accounts', {
        'name': 'Balance card',
        'type': 'bank',
        'balance': 500.0,
        'user_id': 1,
      });
      final oldId = await sa.db.insert('expense_records', {
        'ledger_id': 1,
        'category_id': 1,
        'user_id': 1,
        'type': 'expense',
        'amount': 50.0,
        'date': '2026-10-17T00:00:00',
        'title': 'balance-old',
        'asset_account_id': cardA,
      });
      await AccountBalances.initializeLegacy(sa.db, userId: 1);
      await ea.synchronize();
      await eb.synchronize();
      final cardB =
          (await sb.db.query(
                'asset_accounts',
                where: 'name = ?',
                whereArgs: ['Balance card'],
              )).single['id']
              as int;
      Future<double> balance(CloudSyncStore s, int id) async =>
          ((await AccountBalances.read(
                s.db,
                id: id,
              )).single['current_balance_cents']
              as int) /
          100;
      expect(await balance(sa, cardA), 500);
      expect(await balance(sb, cardB), 500);
      // Independent upgrades publishing identical account data auto-merge.
      await sa.db.update(
        'asset_accounts',
        {'balance_offset_cents': -5000},
        where: 'id=?',
        whereArgs: [cardA],
      );
      await sb.db.update(
        'asset_accounts',
        {'balance_offset_cents': -5000},
        where: 'id=?',
        whereArgs: [cardB],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      expect(await ea.conflicts(), isEmpty);
      expect(await eb.conflicts(), isEmpty);
      Future<int> addBill(
        CloudSyncStore s,
        int ledger,
        int cat,
        int card,
        String title,
        double value, {
        String type = 'expense',
      }) => s.db.insert('expense_records', {
        'ledger_id': ledger,
        'category_id': cat,
        'user_id': s.user,
        'type': type,
        'amount': value,
        'date': '2026-10-17T12:00:00',
        'title': title,
        'asset_account_id': card,
      });
      final newA = await addBill(sa, 1, 1, cardA, 'balance-a', 50);
      await addBill(sb, 40, 70, cardB, 'balance-b', 20);
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      expect(await balance(sa, cardA), 430);
      expect(await balance(sb, cardB), 430);
      final newB =
          (await sb.db.query(
                'expense_records',
                where: 'title=?',
                whereArgs: ['balance-a'],
              )).single['id']
              as int;
      await sa.db.update(
        'expense_records',
        {'amount': 70.0},
        where: 'id=?',
        whereArgs: [newA],
      );
      await sb.db.update(
        'expense_records',
        {'amount': 60.0},
        where: 'id=?',
        whereArgs: [newB],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      final editConflict = (await ea.conflicts()).single;
      await ea.resolve(
        editConflict,
        editConflict.choices.indexWhere(
          (p) => (p['values'] as Map?)?['amount'] == 60.0,
        ),
      );
      await eb.synchronize();
      expect(await balance(sa, cardA), 420);
      expect(await balance(sb, cardB), 420);
      await sa.db.delete('expense_records', where: 'id=?', whereArgs: [newA]);
      await sb.db.update(
        'expense_records',
        {'note': 'offline edit'},
        where: 'id=?',
        whereArgs: [newB],
      );
      await ea.synchronize();
      await eb.synchronize();
      await ea.synchronize();
      final deleteConflict = (await ea.conflicts()).single;
      await ea.resolve(
        deleteConflict,
        deleteConflict.choices.indexWhere((p) => p['deleted'] == true),
      );
      await eb.synchronize();
      await ea.synchronize();
      await eb.synchronize();
      expect(await balance(sa, cardA), 480);
      expect(await balance(sb, cardB), 480);
      await addBill(sb, 40, 90, cardB, 'balance-income', 40, type: 'income');
      await eb.synchronize();
      await ea.synchronize();
      expect(await balance(sa, cardA), 520);
      expect(await balance(sb, cardB), 520);
      // Calibration itself is synced once, followed by ordinary bill changes.
      await AccountBalances.calibrate(sa.db, cardA, 600);
      await ea.synchronize();
      await eb.synchronize();
      await addBill(sb, 40, 70, cardB, 'balance-after-calibration', 10);
      await eb.synchronize();
      await ea.synchronize();
      await eb.synchronize();
      expect(await balance(sa, cardA), 590);
      expect(await balance(sb, cardB), 590);
      expect(
        (await sa.db.query(
          'expense_records',
          where: 'id=?',
          whereArgs: [oldId],
        )).length,
        1,
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
