import 'package:sqflite/sqflite.dart';

/// Metadata is excluded from portable backups; business tables stay unchanged.
class LocalSyncSchema {
  static const tables = {
    'local_sync_control',
    'local_sync_objects',
    'local_sync_queue',
    'local_cloud_binding',
    'local_cloud_revisions',
    'local_cloud_bases',
  };
  static const entities = [
    'ledgers',
    'categories',
    'asset_accounts',
    'budgets',
    'tags',
    'expense_records',
    'record_tags',
    'import_reviews',
    'recurring_bills',
    'recurring_occurrences',
    'refund_sources',
    'refund_events',
  ];
  static String _key(String alias, String table) => table == 'record_tags'
      ? "CAST($alias.record_id AS TEXT) || ':' || CAST($alias.tag_id AS TEXT)"
      : 'CAST($alias.id AS TEXT)';
  static String _owner(String alias, String table) {
    if (table == 'record_tags') {
      return '(SELECT COALESCE(r.user_id,l.user_id) FROM expense_records r '
          'LEFT JOIN ledgers l ON l.id=r.ledger_id WHERE r.id=$alias.record_id)';
    }
    if (table == 'expense_records' || table == 'budgets') {
      return 'COALESCE($alias.user_id,(SELECT user_id FROM ledgers WHERE id=$alias.ledger_id))';
    }
    return '$alias.user_id';
  }

  static const cloudStatements = [
    '''CREATE TABLE IF NOT EXISTS local_cloud_binding(
      scope TEXT NOT NULL,user_id INTEGER NOT NULL,owner_id TEXT NOT NULL,
      vault_uid TEXT NOT NULL,device_uid TEXT NOT NULL,cursor INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(scope,user_id))''',
    '''CREATE TABLE IF NOT EXISTS local_cloud_revisions(
      revision_uid TEXT PRIMARY KEY,owner_id TEXT NOT NULL,vault_uid TEXT NOT NULL,
      object_uid TEXT NOT NULL,body TEXT NOT NULL,local_version INTEGER,change_seq INTEGER,
      UNIQUE(owner_id,vault_uid,object_uid,local_version))''',
    '''CREATE TABLE IF NOT EXISTS local_cloud_bases(
      object_uid TEXT PRIMARY KEY,head_uids TEXT NOT NULL)''',
  ];
  static List<String> get createStatements => [
    ...cloudStatements,
    '''CREATE TABLE IF NOT EXISTS local_sync_control(
      id INTEGER PRIMARY KEY CHECK(id=1),
      capture_enabled INTEGER NOT NULL CHECK(capture_enabled IN (0,1)),
      installation_scope TEXT NOT NULL
    )''',
    '''INSERT OR IGNORE INTO local_sync_control VALUES(1,1,lower(hex(randomblob(16))))''',
    '''CREATE TABLE IF NOT EXISTS local_sync_objects(
      table_name TEXT NOT NULL, local_key TEXT NOT NULL,
      object_uid TEXT NOT NULL UNIQUE, owner_user_id INTEGER,
      local_version INTEGER NOT NULL CHECK(local_version>=1),
      deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
      PRIMARY KEY(table_name,local_key)
    )''',
    '''CREATE TABLE IF NOT EXISTS local_sync_queue(
      object_uid TEXT PRIMARY KEY,
      local_version INTEGER NOT NULL CHECK(local_version>=1)
    )''',
    ...entities.expand(
      (table) => ['INSERT', 'UPDATE', 'DELETE'].map((event) {
        final alias = event == 'DELETE' ? 'OLD' : 'NEW';
        final key = _key(alias, table);
        final owner = _owner(alias, table);
        final deleted = event == 'DELETE' ? 1 : 0;
        final trigger = 'local_sync_capture_${table}_$event';
        return '''CREATE TRIGGER IF NOT EXISTS $trigger
        AFTER $event ON $table
        WHEN (SELECT capture_enabled FROM local_sync_control WHERE id=1)=1
        BEGIN
          INSERT OR IGNORE INTO local_sync_objects
            (table_name,local_key,object_uid,owner_user_id,local_version,deleted)
          VALUES('$table',$key,lower(hex(randomblob(16))),$owner,1,$deleted);
          UPDATE local_sync_objects SET
            local_version=local_version+1,
            owner_user_id=COALESCE($owner,owner_user_id), deleted=$deleted
          WHERE table_name='$table' AND local_key=$key;
          INSERT OR REPLACE INTO local_sync_queue(object_uid,local_version)
          SELECT object_uid,local_version FROM local_sync_objects
          WHERE table_name='$table' AND local_key=$key;
        END''';
      }),
    ),
  ];
  static List<String> get backfillStatements => [
    ...entities.map((table) {
      final key = _key('source', table);
      final owner = _owner('source', table);
      return '''INSERT OR IGNORE INTO local_sync_objects
        (table_name,local_key,object_uid,owner_user_id,local_version,deleted)
        SELECT '$table',$key,lower(hex(randomblob(16))),$owner,1,0 FROM $table source''';
    }),
    '''INSERT OR IGNORE INTO local_sync_queue(object_uid,local_version)
       SELECT object_uid,local_version FROM local_sync_objects''',
  ];
  static Future<void> install(DatabaseExecutor db) async {
    for (final sql in createStatements) {
      await db.execute(sql);
    }
    for (final sql in backfillStatements) {
      await db.execute(sql);
    }
  }

  /// Restore suppression and identity reset are in the same restore transaction.
  static const pauseSql =
      'UPDATE local_sync_control SET capture_enabled=0 WHERE id=1';
  static const resetStatements = [
    'DELETE FROM local_cloud_bases',
    'DELETE FROM local_cloud_revisions',
    'DELETE FROM local_cloud_binding',
    'DELETE FROM local_sync_queue',
    'DELETE FROM local_sync_objects',
    'UPDATE local_sync_control SET capture_enabled=1, '
        'installation_scope=lower(hex(randomblob(16))) WHERE id=1',
  ];
  static Future<void> beginRestore(DatabaseExecutor db) async {
    await db.execute(pauseSql);
  }

  static Future<void> finishRestore(DatabaseExecutor db) async {
    for (final sql in resetStatements) {
      await db.execute(sql);
    }
    for (final sql in backfillStatements) {
      await db.execute(sql);
    }
  }
}
