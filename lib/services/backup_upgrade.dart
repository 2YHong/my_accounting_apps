import '../models/full_backup.dart';
import 'account_balances.dart';

/// Validate legacy data before converting it; never drop or invent business rows.
FullBackupSnapshot upgradeBalanceBackup(
  FullBackupSnapshot snapshot,
  Map<String, List<BackupColumn>> schema,
  int currentVersion,
) {
  if (snapshot.schemaVersion != 7 || currentVersion != 8) return snapshot;
  final oldSchema = {
    ...schema,
    'asset_accounts': schema['asset_accounts']!
        .where((c) => c.name != 'balance_offset_cents')
        .toList(),
  };
  FullBackupValidator.validate(
    snapshot,
    currentSchemaVersion: 7,
    schema: oldSchema,
  );
  final tables = {
    ...snapshot.tables,
    'asset_accounts': snapshot.tables['asset_accounts']!
        .map(
          (account) => <String, Object?>{
            ...account,
            'balance_offset_cents': AccountBalances.snapshotNet(
              account,
              snapshot.tables['expense_records']!,
              snapshot.tables['ledgers']!,
            ),
          },
        )
        .toList(),
  };
  return FullBackupSnapshot(
    schemaVersion: 8,
    createdAt: snapshot.createdAt,
    tables: tables,
    settings: snapshot.settings,
    sequences: snapshot.sequences,
  );
}
