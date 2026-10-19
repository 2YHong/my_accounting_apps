import 'sync_edit_guard.dart';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import '../models/full_backup.dart';
import '../services/account_balances.dart';
import 'local_sync_schema.dart';
import 'local_sync_repository.dart';
import 'revision_crypto.dart';
import 'sync_protocol.dart';

class CloudProjection {
  final int applied, deferred, upgradedAccounts;
  const CloudProjection(
    this.applied,
    this.deferred, {
    this.upgradedAccounts = 0,
  });
}

class CloudBinding {
  final String scope, owner, vault, device;
  final int user, cursor;
  CloudBinding(
    this.scope,
    this.user,
    this.owner,
    this.vault,
    this.device,
    this.cursor,
  );
}

class FrozenChange {
  final String objectUid;
  final int version;
  final List<String> parents;
  final Map<String, Object?> payload;
  FrozenChange(this.objectUid, this.version, this.parents, this.payload);
}

class CloudSyncStore {
  final Database db;
  final String scope;
  final int user;
  CloudSyncStore(this.db, this.scope, this.user);
  static Future<CloudSyncStore> open() async {
    final repo = LocalSyncRepository(),
        state = await LocalSyncRepository().status();
    return CloudSyncStore(
      await repo.helper.database,
      state.installationScope,
      state.userId,
    );
  }

  static const statements = LocalSyncSchema.cloudStatements;
  Future<void> checkScope(DatabaseExecutor tx) async {
    final rows = await tx.query('local_sync_control');
    if (rows.single['installation_scope'] != scope) {
      throw const SyncCryptoException('本地数据已恢复，请重新连接云账号');
    }
  }

  Future<CloudBinding?> binding() async {
    await checkScope(db);
    final rows = await db.query(
      'local_cloud_binding',
      where: 'scope=? AND user_id=?',
      whereArgs: [scope, user],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return CloudBinding(
      scope,
      user,
      r['owner_id'] as String,
      r['vault_uid'] as String,
      r['device_uid'] as String,
      r['cursor'] as int,
    );
  }

  Future<void> bind(String owner, String vault, String device) async {
    await db.transaction((tx) async {
      await checkScope(tx);
      final old = await tx.query(
        'local_cloud_binding',
        where: 'scope=? AND user_id=?',
        whereArgs: [scope, user],
      );
      if (old.isNotEmpty &&
          (old.single['owner_id'] != owner ||
              old.single['vault_uid'] != vault)) {
        throw const SyncCryptoException('本机数据已绑定其他云账号或空间，已阻止混合上传');
      }
      if (old.isEmpty) {
        await tx.insert('local_cloud_binding', {
          'scope': scope,
          'user_id': user,
          'owner_id': owner,
          'vault_uid': vault,
          'device_uid': device,
          'cursor': 0,
        });
      } else if (old.single['device_uid'] != device) {
        throw const SyncCryptoException('本机设备身份不一致');
      }
    });
  }

  static const targets = {
    'ledger_id': 'ledgers',
    'category_id': 'categories',
    'asset_account_id': 'asset_accounts',
    'parent_id': 'categories',
    'record_id': 'expense_records',
    'tag_id': 'tags',
    'rule_id': 'recurring_bills',
    'account_id': 'asset_accounts',
    'expense_category_id': 'categories',
    'income_category_id': 'categories',
  };
  static const entityNames = {
    'ledgers': '账本',
    'categories': '分类',
    'asset_accounts': '资产账户',
    'expense_records': '账单',
    'recurring_bills': '固定收支计划',
    'tags': '标签',
  };

  static bool _historicalLink(String entity, String field, Map values) {
    if (field == 'record_id' &&
        (entity == 'import_reviews' || entity == 'recurring_occurrences')) {
      return values['status'] != 'pending';
    }
    return entity == 'recurring_bills' &&
        ['ledger_id', 'category_id', 'asset_account_id'].contains(field);
  }

  Future<void> _advanceSequence(
    DatabaseExecutor tx,
    String table,
    int id,
  ) async {
    final rows = await tx.query(
      'sqlite_sequence',
      where: 'name=?',
      whereArgs: [table],
    );
    if (rows.isEmpty) {
      await tx.insert('sqlite_sequence', {'name': table, 'seq': id});
    } else if ((rows.single['seq'] as int) < id) {
      await tx.update(
        'sqlite_sequence',
        {'seq': id},
        where: 'name=?',
        whereArgs: [table],
      );
    }
  }

  Future<String?> _uid(
    DatabaseExecutor tx,
    String table,
    Object? key, {
    bool historical = false,
  }) async {
    if (key == null) return null;
    final rows = await tx.query(
      'local_sync_objects',
      where: 'table_name=? AND local_key=? AND owner_user_id=?',
      whereArgs: [table, key.toString(), user],
    );
    if (rows.isNotEmpty) return rows.single['object_uid'] as String;
    final other = await tx.query(
      'local_sync_objects',
      where: 'table_name=? AND local_key=?',
      whereArgs: [table, key.toString()],
    );
    final live = await tx.query(
      table,
      columns: ['id'],
      where: 'id=?',
      whereArgs: [key],
    );
    // A missing historical target is a deleted object, never a bill to recreate.
    // Do not claim live records or metadata belonging to another local user.
    if (historical && key is int && key > 0 && other.isEmpty && live.isEmpty) {
      final uid = newSyncId();
      await tx.insert('local_sync_objects', {
        'table_name': table,
        'local_key': key.toString(),
        'object_uid': uid,
        'owner_user_id': user,
        'local_version': 1,
        'deleted': 1,
      });
      await tx.insert('local_sync_queue', {
        'object_uid': uid,
        'local_version': 1,
      });
      // Missing IDs can exceed MAX(id), including on a receiving device. Reserve
      // them in SQLite so a future insert never inherits a historical identity.
      await _advanceSequence(tx, table, key);
      return uid;
    }
    final label = entityNames[table] ?? '记录';
    throw SyncCryptoException(
      '账单同步尚未完成：本机$label关联无法确认（编号 $key）。现有数据已保留，请将此提示反馈给开发者。',
    );
  }

  Future<Object?> _nestedEncode(DatabaseExecutor tx, Object? value) async {
    if (value is List) {
      final items = <Object?>[];
      for (final item in value) {
        items.add(await _nestedEncode(tx, item));
      }
      return items;
    }
    if (value is! Map) return value;
    final out = <String, Object?>{};
    for (final e in value.entries) {
      final name = e.key as String;
      if (['id', 'user_id', 'cloud_id', 'is_synced'].contains(name)) continue;
      if (name == 'import_key' && e.value is String) {
        out[name] = await _canonicalImportKey(tx, e.value as String);
        continue;
      }
      if (name == 'original') {
        out[name] = e.value;
        continue;
      }
      if (targets.containsKey(name) && e.value != null) {
        out[name] = {
          'ref': await _uid(tx, targets[name]!, e.value, historical: true),
        };
      } else {
        out[name] = await _nestedEncode(tx, e.value);
      }
    }
    return out;
  }

  Future<Map<String, Object?>> _payload(
    DatabaseExecutor tx,
    Map<String, Object?> meta,
  ) async {
    final table = meta['table_name'] as String,
        key = meta['local_key'] as String;
    if (!LocalSyncSchema.entities.contains(table)) {
      throw const SyncCryptoException('未知本地实体');
    }
    if (meta['deleted'] == 1) {
      return {'schema': 1, 'entity': table, 'deleted': true};
    }
    final rows = await tx.query(
      table,
      where: table == 'record_tags' ? 'record_id=? AND tag_id=?' : 'id=?',
      whereArgs: table == 'record_tags'
          ? key.split(':').map(int.parse).toList()
          : [int.parse(key)],
    );
    if (rows.isEmpty) throw const SyncCryptoException('本地实体状态与同步标识不一致');
    final values = <String, Object?>{}, links = <String, Object?>{};
    for (final e in rows.single.entries) {
      if (['id', 'user_id', 'cloud_id', 'is_synced'].contains(e.key)) continue;
      if (e.key == 'import_key' && e.value is String) {
        values[e.key] = await _canonicalImportKey(tx, e.value as String);
      } else if (targets.containsKey(e.key)) {
        links[e.key] = await _uid(
          tx,
          targets[e.key]!,
          e.value,
          historical: _historicalLink(table, e.key, rows.single),
        );
      } else if ((table == 'import_reviews' && e.key == 'payload') ||
          (table == 'recurring_occurrences' &&
              ['snapshot', 'resolution'].contains(e.key) &&
              e.value != null)) {
        values[e.key] = await _nestedEncode(tx, jsonDecode(e.value as String));
      } else {
        values[e.key] = e.value;
      }
    }
    return {
      'schema': 1,
      'entity': table,
      'deleted': false,
      'values': values,
      'links': links,
    };
  }

  Future<List<FrozenChange>> freeze() => db.transaction((tx) async {
    await checkScope(tx);
    final result = <FrozenChange>[], visited = <String>{};
    // Reading legacy snapshots may create metadata for a previously deleted
    // object. Freeze those tombstones in the same transaction and upload batch.
    while (true) {
      final rows = await tx.rawQuery(
        'SELECT o.* FROM local_sync_objects o JOIN local_sync_queue q '
        'ON o.object_uid=q.object_uid WHERE o.owner_user_id=? ORDER BY o.table_name,o.local_key',
        [user],
      );
      final fresh = rows
          .where((r) => !visited.contains(r['object_uid']))
          .toList();
      if (fresh.isEmpty) break;
      for (final r in fresh) {
        final uid = r['object_uid'] as String;
        final bases = await tx.query(
          'local_cloud_bases',
          where: 'object_uid=?',
          whereArgs: [uid],
        );
        result.add(
          FrozenChange(
            uid,
            r['local_version'] as int,
            bases.isEmpty
                ? []
                : List<String>.from(
                    jsonDecode(bases.single['head_uids'] as String) as List,
                  ),
            await _payload(tx, r),
          ),
        );
        visited.add(uid);
      }
    }
    return result;
  });
  Future<EncryptedRevision?> prepared(CloudBinding b, FrozenChange c) async {
    final rows = await db.query(
      'local_cloud_revisions',
      where: 'owner_id=? AND vault_uid=? AND object_uid=? AND local_version=?',
      whereArgs: [b.owner, b.vault, c.objectUid, c.version],
    );
    return rows.isEmpty
        ? null
        : EncryptedRevision.fromWire(
            jsonDecode(rows.single['body'] as String) as Map<String, dynamic>,
          );
  }

  Future<void> savePrepared(
    CloudBinding b,
    FrozenChange c,
    EncryptedRevision r,
  ) => db.transaction((tx) async {
    await checkScope(tx);
    await tx.insert('local_cloud_revisions', {
      'revision_uid': r.revisionUid,
      'owner_id': b.owner,
      'vault_uid': b.vault,
      'object_uid': r.objectUid,
      'body': jsonEncode(r.toWire()),
      'local_version': c.version,
    });
    await tx.insert('local_cloud_bases', {
      'object_uid': r.objectUid,
      'head_uids': jsonEncode([r.revisionUid]),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });
  Future<List<EncryptedRevision>> outgoing(CloudBinding b) async {
    final rows = await db.query(
      'local_cloud_revisions',
      where: 'owner_id=? AND vault_uid=? AND change_seq IS NULL',
      whereArgs: [b.owner, b.vault],
      orderBy: 'rowid',
    );
    return rows
        .map(
          (r) => EncryptedRevision.fromWire(
            jsonDecode(r['body'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Future<void> receipt(CloudBinding b, EncryptedRevision r, int seq) =>
      db.transaction((tx) async {
        await checkScope(tx);
        if (seq < 1) throw const SyncCryptoException('上传确认序号无效');
        final rows = await tx.query(
          'local_cloud_revisions',
          where: 'revision_uid=? AND owner_id=? AND vault_uid=?',
          whereArgs: [r.revisionUid, b.owner, b.vault],
        );
        if (rows.length != 1) throw const SyncCryptoException('上传确认不属于本机版本');
        final version = rows.single['local_version'] as int?;
        await tx.update(
          'local_cloud_revisions',
          {'change_seq': seq},
          where: 'revision_uid=?',
          whereArgs: [r.revisionUid],
        );
        if (version != null) {
          await LocalSyncRepository.acknowledge(
            tx,
            owner: user,
            objectUid: r.objectUid,
            localVersion: version,
          );
        }
      });
  Future<void> cache(CloudBinding b, List<EncryptedRevision> incoming) =>
      db.transaction((tx) async {
        await checkScope(tx);
        final current = (await tx.query(
          'local_cloud_binding',
          where: 'scope=? AND user_id=?',
          whereArgs: [scope, user],
        )).single;
        var cursor = current['cursor'] as int;
        for (final r in incoming) {
          if (r.changeSeq != cursor + 1) {
            throw const SyncCryptoException('云端版本序号不连续，已停止同步');
          }
          final old = await tx.query(
            'local_cloud_revisions',
            where: 'revision_uid=?',
            whereArgs: [r.revisionUid],
          );
          if (old.isNotEmpty) {
            final previous = EncryptedRevision.fromWire(
              jsonDecode(old.single['body'] as String) as Map<String, dynamic>,
            );
            if ((old.single['change_seq'] != null &&
                    old.single['change_seq'] != r.changeSeq) ||
                !previous.sameContent(r)) {
              throw const SyncCryptoException('云端返回了不同内容的同名版本');
            }
            await tx.update(
              'local_cloud_revisions',
              {'change_seq': r.changeSeq},
              where: 'revision_uid=?',
              whereArgs: [r.revisionUid],
            );
          } else {
            await tx.insert('local_cloud_revisions', {
              'revision_uid': r.revisionUid,
              'owner_id': b.owner,
              'vault_uid': b.vault,
              'object_uid': r.objectUid,
              'body': jsonEncode(r.toWire()),
              'change_seq': r.changeSeq,
            });
          }
          cursor = r.changeSeq!;
        }
        await tx.update(
          'local_cloud_binding',
          {'cursor': cursor},
          where: 'scope=? AND user_id=?',
          whereArgs: [scope, user],
        );
      });
  Future<List<EncryptedRevision>> all(
    CloudBinding b, {
    DatabaseExecutor? executor,
  }) async {
    final rows = await (executor ?? db).query(
      'local_cloud_revisions',
      where: 'owner_id=? AND vault_uid=?',
      whereArgs: [b.owner, b.vault],
      orderBy: 'rowid',
    );
    return rows.map((r) {
      final body = jsonDecode(r['body'] as String) as Map<String, dynamic>;
      body['change_seq'] = r['change_seq'];
      return EncryptedRevision.fromWire(body);
    }).toList();
  }

  Future<String> _canonicalImportKey(DatabaseExecutor tx, String value) async {
    final match = RegExp(r'^recurring:(\d+):(\d{4}-\d{2})$').firstMatch(value);
    if (match == null) return value;
    final rule = await _uid(
      tx,
      'recurring_bills',
      int.parse(match[1]!),
      historical: true,
    );
    return 'recurring:$rule:${match[2]!}';
  }

  Future<String> _localImportKey(DatabaseExecutor tx, String value) async {
    final match = RegExp(
      r'^recurring:([A-Za-z0-9_-]{16,64}):(\d{4}-\d{2})$',
    ).firstMatch(value);
    if (match == null) return value;
    final rule = await _resolveUid(tx, match[1], 'recurring_bills');
    return 'recurring:$rule:${match[2]!}';
  }

  Future<void> canonicalizeIdentities(SecretKey rootKey, String vault) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: rootKey,
      nonce: utf8.encode(vault),
      info: utf8.encode('accounting.identity.v1'),
    );
    await db.transaction((tx) async {
      await checkScope(tx);
      for (final table in [
        'expense_records',
        'import_reviews',
        'recurring_occurrences',
        'refund_sources',
        'refund_events',
        'record_tags',
      ]) {
        final rows = await tx.query(
          'local_sync_objects',
          where: 'table_name=? AND owner_user_id=? AND deleted=0',
          whereArgs: [table, user],
        );
        for (final meta in rows) {
          final old = meta['object_uid'] as String;
          if ((await tx.query(
            'local_cloud_bases',
            where: 'object_uid=?',
            whereArgs: [old],
          )).isNotEmpty) {
            continue;
          }
          final local = meta['local_key'] as String;
          final data = await tx.query(
            table,
            where: table == 'record_tags' ? 'record_id=? AND tag_id=?' : 'id=?',
            whereArgs: table == 'record_tags'
                ? local.split(':').map(int.parse).toList()
                : [int.parse(local)],
          );
          if (data.isEmpty) continue;
          final r = data.single;
          Object? identity;
          if (table == 'expense_records' || table == 'refund_sources') {
            final imported = r['import_key'];
            if (imported is String && imported.isNotEmpty) {
              identity = await _canonicalImportKey(tx, imported);
            }
          } else if (table == 'refund_events') {
            identity = [r['source'], r['refund_id']];
          } else if (table == 'import_reviews') {
            identity = [r['source'], r['row_key']];
          } else if (table == 'recurring_occurrences') {
            identity = [
              await _uid(tx, 'recurring_bills', r['rule_id']),
              r['period'],
            ];
          } else if (table == 'record_tags') {
            identity = [
              await _uid(tx, 'expense_records', r['record_id']),
              await _uid(tx, 'tags', r['tag_id']),
            ];
          }
          if (identity == null) continue;
          final mac = await Hmac.sha256().calculateMac(
            utf8.encode(jsonEncode([table, identity])),
            secretKey: key,
          );
          final uid = mac.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          if (uid == old) continue;
          final duplicate = await tx.query(
            'local_sync_objects',
            where: 'object_uid=?',
            whereArgs: [uid],
          );
          if (duplicate.isNotEmpty) {
            throw const SyncCryptoException('本机存在相同来源的重复记录，请先核对，数据没有被覆盖');
          }
          final queued = await tx.query(
            'local_sync_queue',
            where: 'object_uid=?',
            whereArgs: [old],
          );
          await tx.delete(
            'local_sync_queue',
            where: 'object_uid=?',
            whereArgs: [old],
          );
          await tx.update(
            'local_sync_objects',
            {'object_uid': uid},
            where: 'object_uid=?',
            whereArgs: [old],
          );
          if (queued.isNotEmpty) {
            await tx.insert('local_sync_queue', {
              'object_uid': uid,
              'local_version': meta['local_version'],
            });
          }
        }
      }
    });
  }

  Future<Map<String, Object?>?> _meta(DatabaseExecutor tx, String uid) async {
    final rows = await tx.query(
      'local_sync_objects',
      where: 'object_uid=? AND owner_user_id=?',
      whereArgs: [uid, user],
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<int?> _resolveUid(
    DatabaseExecutor tx,
    Object? uid,
    String target,
  ) async {
    if (uid == null) return null;
    if (uid is! String) throw const SyncCryptoException('加密数据中的关联标识无效');
    final row = await _meta(tx, uid);
    if (row == null || row['table_name'] != target) {
      throw const SyncCryptoException('关联对象尚未下载完整，请先同步或处理其冲突');
    }
    return int.parse(row['local_key'] as String);
  }

  Future<Object?> _nestedDecode(DatabaseExecutor tx, Object? value) async {
    if (value is List) {
      return Future.wait(value.map((v) => _nestedDecode(tx, v)));
    }
    if (value is! Map) return value;
    final out = <String, Object?>{};
    for (final e in value.entries) {
      final name = e.key as String;
      if (name == 'import_key' && e.value is String) {
        out[name] = await _localImportKey(tx, e.value as String);
        continue;
      }
      if (name == 'original') {
        out[name] = e.value;
        continue;
      }
      if (targets.containsKey(name) && e.value is Map) {
        out[name] = await _resolveUid(
          tx,
          (e.value as Map)['ref'],
          targets[name]!,
        );
      } else {
        out[name] = await _nestedDecode(tx, e.value);
      }
    }
    return out;
  }

  void _checkPayload(Map<String, dynamic> payload) {
    if (payload['schema'] != 1 ||
        !LocalSyncSchema.entities.contains(payload['entity']) ||
        payload['deleted'] is! bool) {
      throw const SyncCryptoException('加密业务数据格式不受支持');
    }
    if (payload['deleted'] == false &&
        (payload['values'] is! Map || payload['links'] is! Map)) {
      throw const SyncCryptoException('加密业务字段不完整');
    }
  }

  Future<void> _reserve(
    DatabaseExecutor tx,
    String uid,
    Map<String, dynamic> p,
  ) async {
    _checkPayload(p);
    final table = p['entity'] as String;
    final existing = await _meta(tx, uid);
    if (existing != null) {
      if (existing['table_name'] != table) {
        throw const SyncCryptoException('对象类型发生了不允许的变化');
      }
      return;
    }
    if (table == 'record_tags') return;
    // Adopt untouched built-in defaults on a new B device; never guess identities
    // for transactions, custom categories, or locally edited objects.
    if (p['deleted'] == false &&
        (table == 'ledgers' || table == 'categories')) {
      final values = p['values'] as Map;
      final system = table == 'ledgers'
          ? values['is_default'] == 1
          : values['is_system'] == 1;
      if (system) {
        final match = await tx.rawQuery(
          'SELECT o.* FROM local_sync_objects o JOIN $table b ON CAST(b.id AS TEXT)=o.local_key WHERE o.table_name=? AND o.owner_user_id=? AND o.local_version=1 AND o.deleted=0 AND b.name=? ${table == 'categories' ? 'AND b.type=? ' : ''}AND NOT EXISTS(SELECT 1 FROM local_cloud_bases h WHERE h.object_uid=o.object_uid)',
          [
            table,
            user,
            values['name'],
            if (table == 'categories') values['type'],
          ],
        );
        if (match.length == 1) {
          await tx.delete(
            'local_sync_queue',
            where: 'object_uid=?',
            whereArgs: [match.single['object_uid']],
          );
          await tx.update(
            'local_sync_objects',
            {'object_uid': uid},
            where: 'object_uid=?',
            whereArgs: [match.single['object_uid']],
          );
          return;
        }
      }
    }
    final tableMax =
        Sqflite.firstIntValue(
          await tx.rawQuery('SELECT COALESCE(MAX(id),0) FROM $table'),
        ) ??
        0;
    final mapMax =
        Sqflite.firstIntValue(
          await tx.rawQuery(
            'SELECT COALESCE(MAX(CAST(local_key AS INTEGER)),0) FROM local_sync_objects WHERE table_name=?',
            [table],
          ),
        ) ??
        0;
    final seq =
        Sqflite.firstIntValue(
          await tx.rawQuery(
            'SELECT COALESCE(MAX(seq),0) FROM sqlite_sequence WHERE name=?',
            [table],
          ),
        ) ??
        0;
    final key = [tableMax, mapMax, seq].reduce((a, b) => a > b ? a : b) + 1;
    await tx.insert('local_sync_objects', {
      'table_name': table,
      'local_key': key.toString(),
      'object_uid': uid,
      'owner_user_id': user,
      'local_version': 1,
      'deleted': p['deleted'] == true ? 1 : 0,
    });
    await _advanceSequence(tx, table, key);
  }

  Future<void> _apply(
    DatabaseExecutor tx,
    String uid,
    Map<String, dynamic> p,
  ) async {
    _checkPayload(p);
    final table = p['entity'] as String;
    var meta = await _meta(tx, uid);
    if (table == 'record_tags' && meta == null) {
      if (p['deleted'] == true) return;
      final links = p['links'] as Map;
      final record = await _resolveUid(
        tx,
        links['record_id'],
        'expense_records',
      );
      final tag = await _resolveUid(tx, links['tag_id'], 'tags');
      if (record == null || tag == null) {
        throw const SyncCryptoException('标签关联不完整');
      }
      final key = '$record:$tag';
      final duplicate = await tx.query(
        'local_sync_objects',
        where: 'table_name=? AND local_key=?',
        whereArgs: [table, key],
      );
      if (duplicate.isNotEmpty) {
        throw const SyncCryptoException('标签关联身份重复，请保留双方版本后核对');
      }
      await tx.insert('local_sync_objects', {
        'table_name': table,
        'local_key': key,
        'object_uid': uid,
        'owner_user_id': user,
        'local_version': 1,
        'deleted': 0,
      });
      meta = await _meta(tx, uid);
    }
    if (meta == null) throw const SyncCryptoException('本机对象标识缺失');
    final key = meta['local_key'] as String;
    final where = table == 'record_tags' ? 'record_id=? AND tag_id=?' : 'id=?';
    final args = table == 'record_tags'
        ? key.split(':').map(int.parse).toList()
        : [int.parse(key)];
    if (p['deleted'] == true) {
      await tx.delete(table, where: where, whereArgs: args);
    } else {
      final columns = (await tx.rawQuery(
        'PRAGMA table_info("$table")',
      )).map((r) => r['name'] as String).toSet();
      final row = Map<String, Object?>.from(p['values'] as Map);
      // An older client has no checkpoint. Normalize after ALL linked rows
      // have been projected so importing old ciphertext preserves its balance.
      if (table == 'asset_accounts')
        row.putIfAbsent('balance_offset_cents', () => null);
      for (final name in row.keys) {
        if (!columns.contains(name) ||
            ['id', 'user_id', 'cloud_id', 'is_synced'].contains(name) ||
            targets.containsKey(name)) {
          throw const SyncCryptoException('同步内容包含不允许的本机字段');
        }
      }
      for (final e in (p['links'] as Map).entries) {
        if (!columns.contains(e.key) || !targets.containsKey(e.key)) {
          throw const SyncCryptoException('同步关联字段无效');
        }
        row[e.key as String] = await _resolveUid(tx, e.value, targets[e.key]!);
      }
      if (table == 'import_reviews' && row['payload'] != null) {
        row['payload'] = jsonEncode(await _nestedDecode(tx, row['payload']));
      }
      if (row['import_key'] is String) {
        row['import_key'] = await _localImportKey(
          tx,
          row['import_key'] as String,
        );
      }
      if (table == 'recurring_occurrences' && row['resolution'] != null) {
        row['resolution'] = jsonEncode(
          await _nestedDecode(tx, row['resolution']),
        );
      }
      if (table == 'recurring_occurrences' && row['snapshot'] != null) {
        final snapshot = Map<String, Object?>.from(
          await _nestedDecode(tx, row['snapshot']) as Map,
        );
        snapshot['id'] = row['rule_id'];
        snapshot['user_id'] = user;
        row['snapshot'] = jsonEncode(snapshot);
      }
      if (columns.contains('user_id')) row['user_id'] = user;
      if (columns.contains('id')) row['id'] = int.parse(key);
      final found = await tx.query(table, where: where, whereArgs: args);
      if (found.isEmpty) {
        await tx.insert(table, row);
      } else {
        await tx.update(table, row, where: where, whereArgs: args);
      }
    }
    await tx.update(
      'local_sync_objects',
      {'deleted': p['deleted'] == true ? 1 : 0},
      where: 'object_uid=?',
      whereArgs: [uid],
    );
  }

  Future<int> _normalizeLegacyBalances(DatabaseExecutor tx) async {
    final ids = await AccountBalances.initializeLegacy(tx, userId: user);
    for (final id in ids) {
      final rows = await tx.query(
        'local_sync_objects',
        where: 'table_name = ? AND local_key = ? AND owner_user_id = ?',
        whereArgs: ['asset_accounts', id.toString(), user],
      );
      if (rows.length != 1) throw const SyncCryptoException('账户同步标识缺失');
      final uid = rows.single['object_uid'];
      final version = (rows.single['local_version'] as int) + 1;
      await tx.update(
        'local_sync_objects',
        {'local_version': version},
        where: 'object_uid = ?',
        whereArgs: [uid],
      );
      await tx.insert('local_sync_queue', {
        'object_uid': uid,
        'local_version': version,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return ids.length;
  }

  Future<void> _validate(DatabaseExecutor tx) async {
    final schema = <String, List<BackupColumn>>{},
        data = <String, List<Map<String, Object?>>>{},
        sequences = <String, int>{};
    for (final table in FullBackupValidator.tableOrder) {
      schema[table] = (await tx.rawQuery(
        'PRAGMA table_info("$table")',
      )).map(BackupColumn.fromPragma).toList();
      data[table] = await tx.query(table);
      if (table != 'record_tags') {
        sequences[table] = data[table]!.fold<int>(
          0,
          (a, b) => (b['id'] as int) > a ? b['id'] as int : a,
        );
      }
    }
    FullBackupValidator.validate(
      FullBackupSnapshot(
        schemaVersion: 8,
        createdAt: DateTime.now(),
        tables: data,
        settings: {},
        sequences: sequences,
      ),
      currentSchemaVersion: 8,
      schema: schema,
    );
  }

  Future<CloudProjection> project(
    CloudBinding b,
    Map<String, Map<String, dynamic>> payloads,
    List<EncryptedRevision> revisions,
  ) => db.transaction((tx) async {
    await checkScope(tx);
    if (SyncEditGuard.active) return const CloudProjection(0, 1);
    await tx.execute(LocalSyncSchema.pauseSql);
    await tx.execute('PRAGMA defer_foreign_keys = ON');
    final groups = <String, List<EncryptedRevision>>{};
    for (final r in revisions) {
      groups.putIfAbsent(r.objectUid, () => []).add(r);
    }
    // Reserve identities even for conflicts so dependent records can be resolved.
    for (final group in groups.entries) {
      final heads = revisionHeads(group.value);
      for (final r in heads) {
        await _reserve(tx, r.objectUid, payloads[r.revisionUid]!);
      }
    }
    final candidates = <EncryptedRevision>[];
    for (final entry in groups.entries) {
      final heads = revisionHeads(entry.value);
      if (heads.length != 1) continue;
      final head = heads.single;
      if ((await tx.query(
        'local_sync_queue',
        where: 'object_uid=?',
        whereArgs: [head.objectUid],
      )).isNotEmpty) {
        continue;
      }
      final base = await tx.query(
        'local_cloud_bases',
        where: 'object_uid=?',
        whereArgs: [head.objectUid],
      );
      if (base.isNotEmpty &&
          base.single['head_uids'] == jsonEncode([head.revisionUid])) {
        continue;
      }
      candidates.add(head);
    }
    final live = candidates
        .where((r) => payloads[r.revisionUid]!['deleted'] == false)
        .toList();
    var changed = true;
    while (changed) {
      changed = false;
      final promised = live.map((r) => r.objectUid).toSet();
      for (final r in List<EncryptedRevision>.from(live)) {
        final payload = payloads[r.revisionUid]!;
        final links = payload['links'] as Map;
        var available = true;
        for (final link in links.entries) {
          final uid = link.value;
          if (uid == null || promised.contains(uid)) continue;
          if (_historicalLink(
                payload['entity'] as String,
                link.key as String,
                payload['values'] as Map,
              ) &&
              uid is String &&
              await _meta(tx, uid) != null) {
            continue;
          }
          if (uid is! String || !await _live(tx, uid)) {
            available = false;
            break;
          }
        }
        if (!available) {
          live.remove(r);
          changed = true;
        }
      }
    }
    final order = {
      for (var i = 0; i < LocalSyncSchema.entities.length; i++)
        LocalSyncSchema.entities[i]: i,
    };
    live.sort(
      (a, b) => order[payloads[a.revisionUid]!['entity']]!.compareTo(
        order[payloads[b.revisionUid]!['entity']]!,
      ),
    );
    var applied = 0;
    Future<void> apply(EncryptedRevision r) async {
      await _apply(tx, r.objectUid, payloads[r.revisionUid]!);
      await tx.insert('local_cloud_bases', {
        'object_uid': r.objectUid,
        'head_uids': jsonEncode([r.revisionUid]),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      applied++;
    }

    for (final r in live) {
      await apply(r);
    }
    final deleted =
        candidates
            .where((r) => payloads[r.revisionUid]!['deleted'] == true)
            .toList()
          ..sort(
            (a, b) => order[payloads[b.revisionUid]!['entity']]!.compareTo(
              order[payloads[a.revisionUid]!['entity']]!,
            ),
          );
    for (final r in deleted) {
      final meta = await _meta(tx, r.objectUid);
      if (meta != null && await _referenced(tx, meta)) continue;
      await apply(r);
    }
    final upgraded = await _normalizeLegacyBalances(tx);
    await _validate(tx);
    await tx.rawUpdate(
      'UPDATE local_sync_control SET capture_enabled=1 WHERE id=1',
    );
    return CloudProjection(
      applied,
      candidates.length - applied,
      upgradedAccounts: upgraded,
    );
  });
  Future<bool> _live(DatabaseExecutor tx, String uid) async {
    final meta = await _meta(tx, uid);
    if (meta == null) return false;
    final table = meta['table_name'] as String,
        key = meta['local_key'] as String;
    return (await tx.query(
      table,
      columns: table == 'record_tags' ? ['record_id'] : ['id'],
      where: table == 'record_tags' ? 'record_id=? AND tag_id=?' : 'id=?',
      whereArgs: table == 'record_tags'
          ? key.split(':').map(int.parse).toList()
          : [int.parse(key)],
      limit: 1,
    )).isNotEmpty;
  }

  Future<bool> _referenced(
    DatabaseExecutor tx,
    Map<String, Object?> meta,
  ) async {
    final target = meta['table_name'] as String;
    if (target == 'record_tags' ||
        !await _live(tx, meta['object_uid'] as String)) {
      return false;
    }
    final id = int.parse(meta['local_key'] as String);
    for (final table in LocalSyncSchema.entities) {
      final columns = (await tx.rawQuery(
        'PRAGMA table_info("$table")',
      )).map((r) => r['name']).toSet();
      for (final e in targets.entries) {
        if (e.value == target && columns.contains(e.key)) {
          final references = await tx.query(
            table,
            where: '${e.key}=?',
            whereArgs: [id],
          );
          if (references.any((row) => !_historicalLink(table, e.key, row))) {
            return true;
          }
        }
      }
    }
    return false;
  }

  Future<void> resolve(
    CloudBinding b,
    SyncConflict conflict,
    EncryptedRevision merge,
    Map<String, dynamic> choice,
  ) => db.transaction((tx) async {
    await checkScope(tx);
    if (SyncEditGuard.active) {
      throw const SyncCryptoException('请先保存并关闭正在编辑的页面，再处理冲突');
    }
    final pending = await tx.query(
      'local_sync_queue',
      where: 'object_uid=?',
      whereArgs: [conflict.objectUid],
    );
    if (pending.isNotEmpty) {
      throw const SyncCryptoException('这条记录刚有本机修改，请先同步后重新处理冲突');
    }
    final current = await all(b, executor: tx);
    final heads = revisionHeads(
      current.where((r) => r.objectUid == conflict.objectUid),
    );
    final actual = heads.map((r) => r.revisionUid).toSet(),
        expected = conflict.heads.map((r) => r.revisionUid).toSet();
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw const SyncCryptoException('冲突版本已变化，请刷新');
    }
    await tx.execute(LocalSyncSchema.pauseSql);
    await _reserve(tx, merge.objectUid, choice);
    final target = await _meta(tx, merge.objectUid);
    if (choice['deleted'] == true &&
        target != null &&
        await _referenced(tx, target)) {
      throw const SyncCryptoException('此对象仍被本机记录引用，请先处理相关记录，再确认删除');
    }
    await _apply(tx, merge.objectUid, choice);
    final meta = await _meta(tx, merge.objectUid);
    final version = meta == null ? null : (meta['local_version'] as int) + 1;
    await tx.update(
      'local_sync_objects',
      {'local_version': version},
      where: 'object_uid=?',
      whereArgs: [merge.objectUid],
    );
    await tx.insert('local_cloud_revisions', {
      'revision_uid': merge.revisionUid,
      'owner_id': b.owner,
      'vault_uid': b.vault,
      'object_uid': merge.objectUid,
      'body': jsonEncode(merge.toWire()),
      'local_version': version,
    });
    await tx.insert('local_cloud_bases', {
      'object_uid': merge.objectUid,
      'head_uids': jsonEncode([merge.revisionUid]),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _normalizeLegacyBalances(tx);
    await _validate(tx);
    await tx.rawUpdate(
      'UPDATE local_sync_control SET capture_enabled=1 WHERE id=1',
    );
  });
}
