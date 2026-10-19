import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import 'local_sync_schema.dart';

class LocalSyncStatus {
  final String installationScope;
  final int userId, pendingCount;
  const LocalSyncStatus(this.installationScope, this.userId, this.pendingCount);
}

class PendingLocalChange {
  final String table, localKey, objectUid;
  final int localVersion;
  final bool deleted;
  const PendingLocalChange({
    required this.table,
    required this.localKey,
    required this.objectUid,
    required this.localVersion,
    required this.deleted,
  });
  factory PendingLocalChange.fromRow(Map<String, Object?> row) =>
      PendingLocalChange(
        table: row['table_name'] as String,
        localKey: row['local_key'] as String,
        objectUid: row['object_uid'] as String,
        localVersion: row['local_version'] as int,
        deleted: row['deleted'] == 1,
      );
}

/// Local bookkeeping only. No network calls or cloud account binding exist here.
class LocalSyncRepository {
  final DatabaseHelper helper;
  LocalSyncRepository({DatabaseHelper? helper})
    : helper = helper ?? DatabaseHelper();
  Future<LocalSyncStatus> status() async {
    final db = await helper.database;
    final user = await helper.getCurrentUser();
    return db.transaction((txn) async {
      final control = (await txn.query('local_sync_control')).single;
      final count =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM local_sync_queue q JOIN local_sync_objects o '
              'ON o.object_uid=q.object_uid WHERE o.owner_user_id=?',
              [user.id],
            ),
          ) ??
          0;
      return LocalSyncStatus(
        control['installation_scope'] as String,
        user.id!,
        count,
      );
    });
  }

  Future<List<PendingLocalChange>> pending(int owner, {int limit = 200}) async {
    if (owner <= 0 || limit < 1 || limit > 1000) {
      throw ArgumentError('Invalid queue scope');
    }
    final db = await helper.database;
    final rows = await db.rawQuery(
      'SELECT o.* FROM local_sync_queue q JOIN local_sync_objects o '
      'ON o.object_uid=q.object_uid WHERE o.owner_user_id=? '
      'ORDER BY o.table_name,o.local_key LIMIT ?',
      [owner, limit],
    );
    return rows.map(PendingLocalChange.fromRow).toList();
  }

  static const acknowledgeSql =
      'DELETE FROM local_sync_queue WHERE object_uid=? '
      'AND local_version=? AND EXISTS(SELECT 1 FROM local_sync_objects o '
      'WHERE o.object_uid=local_sync_queue.object_uid AND o.owner_user_id=?)';

  /// A transport must call this only AFTER authenticating the server receipt.
  /// Newer local edits are never removed by an older acknowledgement.
  static Future<int> acknowledge(
    DatabaseExecutor txn, {
    required int owner,
    required String objectUid,
    required int localVersion,
  }) {
    if (owner <= 0 || localVersion < 1) {
      throw ArgumentError('Invalid acknowledgement');
    }
    return txn.rawDelete(acknowledgeSql, [objectUid, localVersion, owner]);
  }

  static bool isInternalTable(String name) =>
      LocalSyncSchema.tables.contains(name);
}
