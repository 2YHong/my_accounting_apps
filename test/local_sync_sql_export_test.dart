import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/sync/local_sync_schema.dart';
import 'package:my_accounting_app/sync/local_sync_repository.dart';

void main() {
  test('export exact migration SQL for external SQLite integration checks', () {
    final target = Platform.environment['LOCAL_SYNC_SQL_EXPORT'];
    if (target == null) return;
    File(target).writeAsStringSync(
      jsonEncode({
        'create': LocalSyncSchema.createStatements,
        'backfill': LocalSyncSchema.backfillStatements,
        'entities': LocalSyncSchema.entities,
        'pause': LocalSyncSchema.pauseSql,
        'reset': LocalSyncSchema.resetStatements,
        'acknowledge': LocalSyncRepository.acknowledgeSql,
      }),
    );
  });
}
