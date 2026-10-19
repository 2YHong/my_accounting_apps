import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/full_backup.dart';
import 'backup_codec.dart';
import 'backup_upgrade.dart';
import '../sync/local_sync_schema.dart';
export '../models/full_backup.dart';

class FullBackupService {
  final DatabaseHelper _helper;
  final SharedPreferences? _preferences;
  static const maxEncryptedBytes = BackupCodec.maxEncryptedBytes;
  static bool _restoring = false;
  // Physical v10 adds the portable account balance checkpoint (business v8).
  static int _backupSchemaVersion(int version) =>
      version == 10 ? 8 : (version >= 8 && version <= 9 ? 7 : version);
  FullBackupService({
    DatabaseHelper? databaseHelper,
    SharedPreferences? preferences,
  }) : _helper = databaseHelper ?? DatabaseHelper(),
       _preferences = preferences;

  Future<int> _businessVersion(DatabaseExecutor db) async {
    final version =
        (await db.rawQuery('PRAGMA user_version')).single.values.single as int;
    return _backupSchemaVersion(version);
  }

  Future<Map<String, List<BackupColumn>>> _readSchema(
    DatabaseExecutor db,
  ) async {
    final all = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final existing = all.map((row) => row['name'] as String).toSet();
    if (existing.difference({
      ...FullBackupValidator.tableOrder,
      ...LocalSyncSchema.tables,
      'sqlite_sequence',
      'android_metadata',
    }).isNotEmpty) {
      throw const FullBackupException('数据库包含当前备份版本不支持的数据表，请更新软件后再备份');
    }
    final schema = <String, List<BackupColumn>>{};
    for (final table in FullBackupValidator.tableOrder) {
      if (!existing.contains(table))
        throw const FullBackupException('当前数据库缺少必要数据表，请先更新软件');
      final rows = await db.rawQuery('PRAGMA table_info("$table")');
      schema[table] = rows.map(BackupColumn.fromPragma).toList();
    }
    return schema;
  }

  Map<String, Object> _readSettings(SharedPreferences prefs) {
    final result = <String, Object>{};
    for (final key in FullBackupValidator.settingKeys) {
      final value = prefs.get(key);
      if (value != null) result[key] = value;
    }
    return result;
  }

  Future<FullBackupSnapshot> capture() async {
    if (_restoring) throw const FullBackupException('正在恢复数据，请稍后再备份');
    final db = await _helper.database;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final version = await _businessVersion(db);
    return db.transaction((txn) async {
      final schema = await _readSchema(txn);
      final tables = <String, List<Map<String, Object?>>>{};
      final sequences = <String, int>{};
      for (final table in schema.keys) {
        tables[table] = (await txn.query(
          table,
        )).map((row) => Map<String, Object?>.from(row)).toList();
        if (table != 'record_tags') sequences[table] = 0;
      }
      for (final row in await txn.query('sqlite_sequence')) {
        if (sequences.containsKey(row['name']))
          sequences[row['name'] as String] = row['seq'] as int;
      }
      final snapshot = FullBackupSnapshot(
        schemaVersion: version,
        createdAt: DateTime.now(),
        tables: tables,
        settings: _readSettings(prefs),
        sequences: sequences,
      );
      FullBackupValidator.validate(
        snapshot,
        currentSchemaVersion: version,
        schema: schema,
      );
      return snapshot;
    });
  }

  Future<Uint8List> encrypt(FullBackupSnapshot snapshot, String password) {
    BackupCodec.validatePassword(password);
    return compute(encryptBackupWorker, {
      'snapshot': snapshot.toJson(),
      'password': password,
    });
  }

  Future<Uint8List> createEncryptedBackup(String password) async =>
      encrypt(await capture(), password);

  Future<FullBackupSnapshot> open(Uint8List bytes, String password) async {
    final decoded = await compute(decryptBackupWorker, {
      'bytes': bytes,
      'password': password,
    });
    var snapshot = FullBackupSnapshot.fromJson(decoded);
    final db = await _helper.database;
    final schema = await _readSchema(db);
    final version = await _businessVersion(db);
    snapshot = upgradeBalanceBackup(snapshot, schema, version);
    FullBackupValidator.validate(
      snapshot,
      currentSchemaVersion: version,
      schema: schema,
    );
    return snapshot;
  }

  Future<void> _writeSettings(
    SharedPreferences prefs,
    Map<String, Object> settings,
  ) async {
    for (final key in FullBackupValidator.settingKeys) {
      final value = settings[key];
      final bool saved;
      if (value == null) {
        saved = prefs.containsKey(key) ? await prefs.remove(key) : true;
      } else if (value is bool) {
        saved = await prefs.setBool(key, value);
      } else if (value is int) {
        saved = await prefs.setInt(key, value);
      } else if (value is String) {
        saved = await prefs.setString(key, value);
      } else {
        throw const FullBackupException('备份设置类型无效');
      }
      if (!saved) throw const FullBackupException('设置保存失败');
    }
  }

  Future<void> restore(FullBackupSnapshot snapshot) async {
    if (_restoring) throw const FullBackupException('正在恢复数据，请勿重复操作');
    _restoring = true;
    Map<String, Object>? previousSettings;
    SharedPreferences? prefs;
    var settingsTouched = false;
    try {
      final db = await _helper.database;
      prefs = _preferences ?? await SharedPreferences.getInstance();
      previousSettings = _readSettings(prefs);
      final version = await _businessVersion(db);
      await db.transaction((txn) async {
        final schema = await _readSchema(txn);
        snapshot = upgradeBalanceBackup(snapshot, schema, version);
        FullBackupValidator.validate(
          snapshot,
          currentSchemaVersion: version,
          schema: schema,
        );
        await LocalSyncSchema.beginRestore(txn);
        await txn.execute('PRAGMA defer_foreign_keys = ON');
        for (final table in FullBackupValidator.tableOrder.reversed) {
          await txn.delete(table);
        }
        // SQLite can defer foreign keys until commit, allowing category parents
        // to be restored without relying on the order of their integer IDs.
        for (final table in FullBackupValidator.tableOrder) {
          for (final row in snapshot.tables[table]!) {
            await txn.insert(table, row);
          }
          if (table != 'record_tags') {
            await txn.delete(
              'sqlite_sequence',
              where: 'name = ?',
              whereArgs: [table],
            );
            await txn.insert('sqlite_sequence', {
              'name': table,
              'seq': snapshot.sequences[table]!,
            });
          }
        }
        final violations = await txn.rawQuery('PRAGMA foreign_key_check');
        if (violations.isNotEmpty)
          throw const FullBackupException('备份存在无效数据关联，恢复已取消');
        await LocalSyncSchema.finishRestore(txn);
        // Settings are written before the SQL commit. Any write/commit failure
        // rolls back all database rows and compensates the preference changes.
        settingsTouched = true;
        await _writeSettings(prefs!, snapshot.settings);
      });
    } catch (_) {
      if (settingsTouched && prefs != null && previousSettings != null) {
        var recovered = false;
        for (var attempt = 0; attempt < 3 && !recovered; attempt++) {
          try {
            await _writeSettings(prefs, previousSettings);
            recovered = true;
          } catch (_) {
            /* retry bounded */
          }
        }
        if (!recovered)
          throw const FullBackupException('数据库恢复已取消，但原设置还原失败，请关闭软件后重试');
      }
      throw const FullBackupException('恢复失败，原有数据库已保留；请检查备份文件后重试');
    } finally {
      _restoring = false;
    }
  }
}
