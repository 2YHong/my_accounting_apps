import 'dart:convert';

class FullBackupException implements Exception {
  final String message;
  const FullBackupException(this.message);
  @override
  String toString() => message;
}

/// A data-only archive. SQL and operating-system permissions are never
/// interpreted or restored from this object.
class FullBackupSnapshot {
  final int schemaVersion;
  final DateTime createdAt;
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object> settings;
  final Map<String, int> sequences;

  FullBackupSnapshot({required this.schemaVersion, required this.createdAt,
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, Object> settings, Map<String, int> sequences = const {}})
      : tables = Map<String,List<Map<String,Object?>>>.unmodifiable(tables.map((name, rows) => MapEntry(name,
          List<Map<String,Object?>>.unmodifiable(rows.map((row) => Map<String, Object?>.unmodifiable(row)))))),
        settings = Map<String,Object>.unmodifiable(settings), sequences = Map<String,int>.unmodifiable(sequences);

  Map<String, int> get rowCounts => tables.map((table, rows) => MapEntry(table, rows.length));
  Map<String, Object?> toJson() => {'format': 'my_accounting_app.full_snapshot',
    'version': 1, 'schema_version': schemaVersion, 'created_at': createdAt.toIso8601String(),
    'tables': tables, 'settings': settings, 'sequences': sequences};

  factory FullBackupSnapshot.fromJson(Map<String, dynamic> map) {
    if (!_exactKeys(map, {'format','version','schema_version','created_at','tables','settings','sequences'}) ||
        map['format'] != 'my_accounting_app.full_snapshot' || map['version'] != 1 ||
        map['schema_version'] is! int || map['created_at'] is! String ||
        map['tables'] is! Map || map['settings'] is! Map || map['sequences'] is! Map) {
      throw const FullBackupException('备份格式不正确或版本不受支持');
    }
    final createdAt = DateTime.tryParse(map['created_at'] as String);
    final calendar = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T').firstMatch(map['created_at'] as String);
    if (createdAt == null || calendar == null) throw const FullBackupException('备份时间无效');
    final year = int.parse(calendar[1]!); final month = int.parse(calendar[2]!); final day = int.parse(calendar[3]!);
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > DateTime(year,month + 1,0).day) {
      throw const FullBackupException('备份时间无效');
    }
    final tables = <String, List<Map<String, Object?>>>{};
    var totalRows = 0;
    for (final entry in (map['tables'] as Map).entries) {
      if (entry.key is! String || entry.value is! List) {
        throw const FullBackupException('备份数据表格式无效');
      }
      final rows = <Map<String, Object?>>[];
      for (final value in entry.value as List) {
        if (value is! Map || value.keys.any((key) => key is! String)) {
          throw const FullBackupException('备份记录格式无效');
        }
        final row = <String, Object?>{};
        for (final field in value.entries) {
          if (field.value != null && field.value is! String && field.value is! num) {
            throw const FullBackupException('备份包含不支持的数据类型');
          }
          if (field.value is num && !(field.value as num).isFinite) {
            throw const FullBackupException('备份包含无效金额');
          }
          row[field.key as String] = field.value as Object?;
        }
        rows.add(row);
        if (++totalRows > 250000) throw const FullBackupException('备份记录数量超出支持范围');
      }
      tables[entry.key as String] = rows;
    }
    final settings = <String, Object>{};
    for (final entry in (map['settings'] as Map).entries) {
      if (entry.key is! String || (entry.value is! String && entry.value is! bool && entry.value is! int)) {
        throw const FullBackupException('备份设置格式无效');
      }
      settings[entry.key as String] = entry.value as Object;
    }
    final sequences = <String, int>{};
    for (final entry in (map['sequences'] as Map).entries) {
      if (entry.key is! String || entry.value is! int || (entry.value as int) < 0) {
        throw const FullBackupException('备份编号状态无效');
      }
      sequences[entry.key as String] = entry.value as int;
    }
    return FullBackupSnapshot(schemaVersion: map['schema_version'] as int,
      createdAt: createdAt, tables: tables, settings: settings, sequences: sequences);
  }

  static bool _exactKeys(Map map, Set<String> names) =>
    map.length == names.length && map.keys.every(names.contains);
}

class BackupColumn {
  final String name;
  final String type;
  final bool notNull;
  final int primaryKey;
  const BackupColumn(this.name, this.type, {this.notNull = false, this.primaryKey = 0});
  factory BackupColumn.fromPragma(Map<String, Object?> row) => BackupColumn(
    row['name'] as String, (row['type'] as String).toUpperCase(),
    notNull: row['notnull'] == 1, primaryKey: row['pk'] as int);
}

/// Validates against columns read from the app's own database, never an SQL
/// declaration from the archive. The logical checks also cover tables whose
/// older migrations did not declare SQLite foreign keys.
class FullBackupValidator {
  static const tableOrder = ['users', 'ledgers', 'categories', 'asset_accounts',
    'budgets', 'tags', 'expense_records', 'record_tags', 'import_reviews',
    'recurring_bills', 'recurring_occurrences', 'refund_sources', 'refund_events'];
  static const boolSettings = {'dark_mode','budget_enabled','auto_sync','backup_enabled',
    'month_start_monday','hide_home_income','hide_assets','hide_liabilities',
    'eye_comfort','recurring_monthly_reminders'};
  static const intSettings = {'theme_seed','current_ledger_id','current_month_offset'};
  static const stringSettings = {'currency','language'};
  static const settingKeys = {...boolSettings, ...intSettings, ...stringSettings};
  static const _bases = {'none','cumulative','events','export'};

  static void validate(FullBackupSnapshot snapshot,
    {required int currentSchemaVersion, required Map<String, List<BackupColumn>> schema}) {
    void fail(String message) => throw FullBackupException(message);
    if (snapshot.schemaVersion != currentSchemaVersion) {
      fail(snapshot.schemaVersion > currentSchemaVersion
        ? '备份来自较新版本，请先更新软件再恢复' : '备份数据库版本不同，请使用相同版本的软件恢复');
    }
    if (schema.keys.toSet().difference(tableOrder.toSet()).isNotEmpty ||
        snapshot.tables.length != schema.length ||
        !schema.keys.every(snapshot.tables.containsKey)) fail('备份缺少数据表或包含未知数据表');
    if (snapshot.tables.values.fold<int>(0,(total,rows) => total + rows.length) > 250000) {
      fail('备份记录数量超出支持范围');
    }
    final index = <String, Map<int, Map<String, Object?>>>{};
    for (final table in schema.keys) {
      final columns = schema[table]!;
      final names = columns.map((column) => column.name).toSet();
      final ids = <int, Map<String, Object?>>{};
      final primaryKeys = columns.where((c) => c.primaryKey > 0).toList()
        ..sort((a,b) => a.primaryKey.compareTo(b.primaryKey));
      final keys = <String>{};
      for (final row in snapshot.tables[table]!) {
        if (row.length != columns.length || row.keys.any((name) => !names.contains(name))) {
          fail('备份字段不完整或包含未知字段：$table');
        }
        for (final column in columns) {
          final value = row[column.name];
          if (value == null) {
            if (column.notNull || column.primaryKey > 0) fail('备份必要字段为空：$table');
          } else if ((column.type.contains('INT') && value is! int) ||
              ((column.type.contains('REAL') || column.type.contains('NUM') || column.type.contains('DOUBLE')) &&
                (value is! num || !value.isFinite)) ||
              ((column.type.contains('TEXT') || column.type.contains('CHAR')) && value is! String) ||
              column.type.contains('BLOB')) {
            fail('备份字段类型不正确：$table');
          }
        }
        final primary = jsonEncode(primaryKeys.map((c) => row[c.name]).toList());
        if (!keys.add(primary)) fail('备份包含重复编号：$table');
        if (row.containsKey('id')) {
          final id = row['id'];
          if (id is! int || id <= 0) fail('备份编号无效：$table');
          ids[id as int] = row;
        }
      }
      index[table] = ids;
      if (table != 'record_tags') {
        final sequence = snapshot.sequences[table];
        final maxId = ids.keys.fold<int>(0, (largest,id) => id > largest ? id : largest);
        if (sequence == null || sequence < maxId) fail('备份自增编号不完整：$table');
      }
    }
    if (snapshot.sequences.keys.any((table) => !schema.containsKey(table) || table == 'record_tags')) {
      fail('备份包含未知自增编号');
    }
    if ((index['users']?.isEmpty ?? true) || (index['ledgers']?.isEmpty ?? true)) fail('备份缺少用户或账本');

    Map<String, Object?>? reference(Map<String, Object?> row, String field, String target,
      {bool required = false, bool checkOwner = true, bool historical = false}) {
      final id = row[field];
      if (id == null) {
        if (required) fail('备份关联缺失：$field');
        return null;
      }
      if (id is! int || id <= 0) fail('备份关联编号无效：$field');
      final targetIndex = index[target];
      final referenced = targetIndex == null ? null : targetIndex[id];
      if (referenced == null) {
        if (!historical) fail('备份关联不存在：$field');
        return null;
      }
      final owner = row['user_id'] ?? index['ledgers']?[row['ledger_id']]?['user_id'];
      final targetOwner = referenced['user_id'] ?? index['ledgers']?[referenced['ledger_id']]?['user_id'];
      if (checkOwner && owner != null && targetOwner != null &&
          owner != targetOwner) fail('备份存在跨用户数据关联');
      return referenced;
    }
    void unique(String table, List<String> fields, {bool nullable = false}) {
      final seen = <String>{};
      for (final row in snapshot.tables[table] ?? const <Map<String,Object?>>[]) {
        if (nullable && fields.any((f) => row[f] == null)) continue;
        if (!seen.add(jsonEncode(fields.map((f) => row[f]).toList()))) fail('备份包含重复数据：$table');
      }
    }
    void enumValue(Map<String,Object?> row, String field, Set<String> values, {bool optional = false}) {
      if (optional && row[field] == null) return;
      if (!values.contains(row[field])) fail('备份状态无效：$field');
    }
    void date(Map<String,Object?> row, String field, {bool optional = false}) {
      final value = row[field];
      if (optional && value == null) return;
      if (value is! String || DateTime.tryParse(value) == null) fail('备份日期无效：$field');
      final calendar = value is String ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T|$)').firstMatch(value) : null;
      if (calendar == null) fail('备份日期无效：$field');
      final matched = calendar!;
      final year = int.parse(matched[1]!); final month = int.parse(matched[2]!); final day = int.parse(matched[3]!);
      if (year < 1 || month < 1 || month > 12 || day < 1 || day > DateTime(year,month + 1,0).day) {
        fail('备份日期无效：$field');
      }
    }
    Map<String,dynamic> jsonObject(Object? value, String field) {
      try {
        if (value is! String) fail('备份内容无效：$field');
        final decoded = jsonDecode(value as String);
        if (decoded is! Map<String,dynamic>) fail('备份内容无效：$field');
        return decoded as Map<String,dynamic>;
      } on FullBackupException { rethrow; }
      catch (_) { fail('备份内容无效：$field'); }
      throw const FullBackupException('备份内容无效');
    }
    void recordSnapshot(Map<String,dynamic> payload, int? userId, {bool historical = true}) {
      final columns = schema['expense_records']!;
      final names = columns.map((column) => column.name).toSet();
      if (payload.keys.any((key) => !names.contains(key))) fail('备份账单快照包含未知字段');
      for (final column in columns) {
        final value = payload[column.name];
        if (value == null) continue;
        if ((column.type.contains('INT') && value is! int) ||
          (column.type.contains('REAL') && (value is! num || !value.isFinite)) ||
          (column.type.contains('TEXT') && value is! String)) fail('备份账单快照字段类型无效');
      }
      final row = Map<String,Object?>.from(payload)..['user_id'] = userId ?? payload['user_id'];
      enumValue(row,'type',{'expense','income'});
      if (row['amount'] is! num || !(row['amount'] as num).isFinite || (row['amount'] as num) < 0) {
        fail('备份账单快照金额无效');
      }
      date(row,'date');
      reference(row,'ledger_id','ledgers',required: true,historical: historical);
      reference(row,'category_id','categories',required: true,historical: historical);
      reference(row,'asset_account_id','asset_accounts',historical: historical);
      if (payload['user_id'] != null && userId != null && payload['user_id'] != userId) {
        fail('备份账单快照用户不一致');
      }
    }

    for (final entry in snapshot.tables.entries) {
      for (final row in entry.value) {
        if (entry.key != 'users' && row.containsKey('user_id')) reference(row,'user_id','users',checkOwner:false);
        switch (entry.key) {
          case 'users':
            date(row,'created_at',optional:true);
            break;
          case 'ledgers':
            if (row['is_default'] != null && row['is_default'] != 0 && row['is_default'] != 1) fail('账本状态无效');
            break;
          case 'categories':
            enumValue(row,'type',{'expense','income','ignore'});
            reference(row,'parent_id','categories');
            if (row['parent_id'] == row['id']) fail('分类存在循环关联');
            break;
          case 'asset_accounts':
            reference(row,'category_id','categories');
            break;
          case 'budgets':
            reference(row,'ledger_id','ledgers',required:true);
            reference(row,'category_id','categories');
            if ((row['amount'] as num) < 0) fail('预算金额无效');
            date(row,'start_date'); date(row,'end_date');
            break;
          case 'expense_records':
            reference(row,'ledger_id','ledgers',required:true);
            final category = reference(row,'category_id','categories',required:true);
            reference(row,'asset_account_id','asset_accounts');
            enumValue(row,'type',{'expense','income'});
            if (category?['type'] != row['type']) fail('账单分类与收支类型不一致');
            if ((row['amount'] as num) < 0) fail('账单金额无效');
            if (row.containsKey('is_synced') && row['is_synced'] != null &&
              row['is_synced'] != 0 && row['is_synced'] != 1) fail('账单同步状态无效');
            date(row,'date');
            enumValue(row,'refund_basis',_bases,optional:true);
            final gross = row['refund_gross_cents']; final total = row['refund_total_cents'];
            if ((gross == null) != (total == null) || (gross != null &&
              (gross is! int || total is! int || gross < 0 || total < 0 || total > gross))) fail('账单退款金额无效');
            break;
          case 'record_tags':
            final record = reference(row,'record_id','expense_records',required:true,checkOwner:false);
            final tag = reference(row,'tag_id','tags',required:true,checkOwner:false);
            final recordOwner = record?['user_id'] ?? index['ledgers']?[record?['ledger_id']]?['user_id'];
            if (recordOwner != null && tag?['user_id'] != null && recordOwner != tag?['user_id']) {
              fail('标签存在跨用户关联');
            }
            break;
          case 'import_reviews':
            enumValue(row,'status',{'pending','resolved','ignored'}); date(row,'created_at');
            reference(row,'record_id','expense_records',historical: row['status'] != 'pending');
            final payload = jsonObject(row['payload'],'待核对账单');
            if (payload['file_name'] is! String || payload['original'] is! Map ||
                (payload['original'] as Map).values.any((v) => v is! String)) {
              fail('待核对账单原文无效');
            }
            final refs = Map<String,Object?>.from(payload)..['user_id'] = row['user_id'];
            // Historical references can point to an account/ledger deleted after
            // the original import. Existing targets must still belong to this user.
            reference(refs,'ledger_id','ledgers',required:true,historical:true);
            reference(refs,'account_id','asset_accounts',historical:true);
            reference(refs,'expense_category_id','categories',required:true,historical:true);
            reference(refs,'income_category_id','categories',required:true,historical:true);
            for (final key in ['candidate','previous_record']) {
              if (payload[key] != null) {
                if (payload[key] is! Map<String,dynamic>) fail('待核对账单快照无效');
                recordSnapshot(payload[key] as Map<String,dynamic>,row['user_id'] as int?);
              }
            }
            break;
          case 'recurring_bills':
            enumValue(row,'type',{'expense','income'});
            if ((row['amount_cents'] as int) <= 0 || (row['day_of_month'] as int) < 1 ||
                (row['day_of_month'] as int) > 31 || (row['enabled'] != 0 && row['enabled'] != 1)) fail('固定收支设置无效');
            reference(row,'ledger_id','ledgers',required:true,historical:true);
            final category = reference(row,'category_id','categories',required:true,historical:true);
            if (category != null && category['type'] != row['type']) fail('固定收支分类类型不一致');
            reference(row,'asset_account_id','asset_accounts',historical:true);
            for (final field in ['start_date','active_from','created_at','updated_at']) { date(row,field); }
            date(row,'deleted_at',optional:true);
            break;
          case 'recurring_occurrences':
            reference(row,'rule_id','recurring_bills',required:true);
            reference(row,'record_id','expense_records',historical:row['status'] != 'pending');
            enumValue(row,'status',{'pending','confirmed','skipped'});
            if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(row['period'] as String)) fail('固定收支期次无效');
            date(row,'due_date'); date(row,'created_at'); date(row,'resolved_at',optional:true);
            final payload = jsonObject(row['snapshot'],'固定收支');
            final refs = Map<String,Object?>.from(payload);
            if (payload['id'] != row['rule_id'] || payload['user_id'] != row['user_id']) fail('固定收支快照关联无效');
            if (payload['title'] is! String || (payload['note'] != null && payload['note'] is! String) ||
              (payload['enabled'] != 0 && payload['enabled'] != 1)) fail('固定收支快照字段无效');
            reference(refs,'ledger_id','ledgers',required:true,historical:true);
            reference(refs,'category_id','categories',required:true,historical:true);
            reference(refs,'asset_account_id','asset_accounts',historical:true);
            enumValue(refs,'type',{'expense','income'});
            if (payload['amount_cents'] is! int || (payload['amount_cents'] as int) <= 0 ||
              payload['day_of_month'] is! int || (payload['day_of_month'] as int) < 1 ||
              (payload['day_of_month'] as int) > 31) fail('固定收支快照金额或日期无效');
            date(refs,'start_date'); date(refs,'active_from');
            if (row['status'] == 'confirmed') {
              final resolution = jsonObject(row['resolution'],'固定收支确认');
              if (resolution['action'] == 'linked_existing') {
                if (resolution['record'] is! Map<String,dynamic>) fail('固定收支确认账单无效');
                recordSnapshot(resolution['record'] as Map<String,dynamic>,row['user_id'] as int?);
              } else { recordSnapshot(resolution,row['user_id'] as int?); }
            }
            break;
          case 'refund_sources':
            reference(row,'record_id','expense_records'); enumValue(row,'basis',_bases);
            final gross = row['gross_cents'] as int; final refund = row['refund_cents'] as int;
            if (gross <= 0 || refund < 0 || refund > gross || (row['version'] as int) <= 0 ||
              (row['manually_edited'] != 0 && row['manually_edited'] != 1)) fail('退款累计状态无效');
            date(row,'snapshot_at',optional:true);
            final original = jsonObject(row['original_json'],'退款原文');
            if (original.values.any((value) => value is! String)) fail('退款原文字段无效');
            break;
          case 'refund_events':
            if ((row['amount_cents'] as int) <= 0) fail('退款明细金额无效');
            date(row,'refunded_at',optional:true);
            final original = jsonObject(row['original_json'],'退款原文');
            if (original.values.any((value) => value is! String)) fail('退款原文字段无效');
            break;
        }
      }
    }
    unique('users',['cloud_uid'],nullable:true);
    for (final table in ['ledgers','budgets','expense_records']) { unique(table,['cloud_id'],nullable:true); }
    unique('expense_records',['user_id','import_key'],nullable:true);
    final importKeys = <String>{};
    for (final record in snapshot.tables['expense_records']!) {
      final importKey = record['import_key'];
      if (importKey == null) continue;
      if (importKey is! String || importKey.trim().isEmpty) fail('账单导入标识无效');
      final owner = record['user_id'] ?? index['ledgers']?[record['ledger_id']]?['user_id'];
      if (!importKeys.add(jsonEncode([owner,importKey]))) fail('同一用户包含重复导入账单');
    }
    unique('import_reviews',['user_id','row_key']); unique('recurring_occurrences',['rule_id','period']);
    unique('refund_sources',['user_id','import_key']); unique('refund_events',['user_id','source','refund_id']);
    final refundSources = <String,Map<String,Object?>>{
      for (final row in snapshot.tables['refund_sources'] ?? const <Map<String,Object?>>[])
        jsonEncode([row['user_id'],row['import_key']]): row};
    final eventTotals = <String,int>{};
    for (final event in snapshot.tables['refund_events'] ?? const <Map<String,Object?>>[]) {
      final key = jsonEncode([event['user_id'],event['import_key']]);
      final source = refundSources[key];
      if (source == null || source['basis'] != 'events') fail('退款明细与累计方式不一致');
      eventTotals[key] = (eventTotals[key] ?? 0) + (event['amount_cents'] as int);
    }
    for (final entry in refundSources.entries) {
      final source = entry.value;
      if (source['basis'] == 'events' && (eventTotals[entry.key] ?? 0) != source['refund_cents']) {
        fail('退款明细合计与累计退款不一致');
      }
      if (source['record_id'] != null) {
        final record = index['expense_records']![source['record_id']]!;
        final owner = record['user_id'] ?? index['ledgers']?[record['ledger_id']]?['user_id'];
        if (record['import_key'] != source['import_key'] || owner != source['user_id']) {
          fail('退款来源与账单关联不一致');
        }
        if (record['refund_gross_cents'] != null && (record['refund_gross_cents'] != source['gross_cents'] ||
          record['refund_total_cents'] != source['refund_cents'] || record['refund_basis'] != source['basis'])) {
          fail('退款来源与账单累计金额不一致');
        }
        if (source['manually_edited'] == 0 && ((record['amount'] as num) -
          ((source['gross_cents'] as int) - (source['refund_cents'] as int)) / 100).abs() > .000001) {
          fail('账单净额与退款累计金额不一致');
        }
      }
    }
    for (final category in index['categories']!.values) {
      final visited = <int>{}; Map<String,Object?>? current = category;
      while (current != null && current['parent_id'] != null) {
        if (!visited.add(current['id'] as int)) fail('分类存在循环关联');
        current = index['categories']![current['parent_id'] as int];
      }
    }
    for (final entry in snapshot.settings.entries) {
      if (!settingKeys.contains(entry.key) ||
        (boolSettings.contains(entry.key) && entry.value is! bool) ||
        (intSettings.contains(entry.key) && entry.value is! int) ||
        (stringSettings.contains(entry.key) && entry.value is! String)) fail('备份包含未知设置或设置类型无效');
    }
    final selectedLedger = snapshot.settings['current_ledger_id'];
    if (selectedLedger != null && !index['ledgers']!.containsKey(selectedLedger)) fail('备份选中的账本不存在');
  }
}
