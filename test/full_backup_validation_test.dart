import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/full_backup.dart';

Map<String,List<BackupColumn>> testSchema(Map<String,List<Map<String,Object?>>> tables) => tables.map(
  (name,rows) => MapEntry(name,rows.isEmpty ? [const BackupColumn('id','INTEGER',primaryKey:1)] :
    rows.first.entries.map((entry) => BackupColumn(entry.key,
      entry.value is num ? (entry.value is int ? 'INTEGER' : 'REAL') :
      {'parent_id','asset_account_id','refund_gross_cents','refund_total_cents','record_id'}.contains(entry.key)
        ? 'INTEGER' : 'TEXT',
      primaryKey:entry.key == 'id' ? 1 : 0,notNull:entry.key == 'id')).toList()));

Map<String,List<Map<String,Object?>>> fixture() => {
  for (final table in FullBackupValidator.tableOrder) table: <Map<String,Object?>>[],
  'users':[{'id':1,'username':'本地用户','cloud_uid':'local_test'}],
  'ledgers':[{'id':1,'name':'总账本','is_default':1,'cloud_id':'ledger_test','user_id':1}],
  'categories':[
    {'id':1,'name':'购物','type':'expense','parent_id':null,'user_id':1},
    {'id':2,'name':'工资','type':'income','parent_id':null,'user_id':1}],
  'asset_accounts':[{'id':1,'name':'银行卡','balance':500.0,'category_id':null,'user_id':1}],
  'expense_records':[{'id':1,'ledger_id':1,'type':'expense','amount':70.0,'category_id':1,
    'asset_account_id':1,'date':'2026-10-01T12:00:00.000','import_key':'wechat:order_1',
    'cloud_id':'record_test','user_id':1,'refund_gross_cents':10000,'refund_total_cents':3000,
    'refund_basis':'events'}],
  'refund_sources':[{'id':1,'user_id':1,'import_key':'wechat:order_1','gross_cents':10000,
    'refund_cents':3000,'basis':'events','snapshot_at':'2026-10-14T12:00:00.000',
    'record_id':1,'manually_edited':0,'version':2,'original_json':'{"商品":"牛奶"}'}],
  'refund_events':[{'id':1,'user_id':1,'source':'微信','refund_id':'refund_1',
    'import_key':'wechat:order_1','amount_cents':3000,'refunded_at':'2026-10-13T12:00:00.000',
    'original_json':'{"退款金额":"30.00"}'}],
};

FullBackupSnapshot snapshot(Map<String,List<Map<String,Object?>>> tables,
  {int schemaVersion = 7, Map<String,Object> settings = const {'current_ledger_id':1,'hide_assets':true}}) =>
  FullBackupSnapshot(schemaVersion:schemaVersion,createdAt:DateTime(2026,10,14),tables:tables,
    settings:settings,sequences:{for (final table in tables.keys)
      if (table != 'record_tags') table: tables[table]!.fold<int>(0,
        (largest,row) => (row['id'] as int) > largest ? row['id'] as int : largest)});

void main() {
  late Map<String,List<Map<String,Object?>>> tables;
  late Map<String,List<BackupColumn>> schema;
  setUp(() { tables = fixture(); schema = testSchema(tables); });
  void validate(FullBackupSnapshot value) => FullBackupValidator.validate(value,
    currentSchemaVersion:7,schema:schema);

  test('完整快照包含退款状态、设置并可序列化往返',() {
    final value = snapshot(tables);
    validate(value);
    final restored = FullBackupSnapshot.fromJson(jsonDecode(jsonEncode(value.toJson())) as Map<String,dynamic>);
    validate(restored);
    expect(restored.tables['refund_sources']!.single['refund_cents'],3000);
    expect(restored.settings['hide_assets'],true);
    expect(restored.sequences['expense_records'],1);
  });
  test('缺失数据表和未知字段拒绝恢复',() {
    final missing = Map<String,List<Map<String,Object?>>>.from(tables)..remove('refund_events');
    expect(() => validate(snapshot(missing)),throwsA(isA<FullBackupException>()));
    tables['expense_records']!.single['secret_sql'] = 'DELETE FROM users';
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
  test('较新数据库版本、损坏外键、跨用户关联被拒绝',() {
    expect(() => validate(snapshot(tables,schemaVersion:8)),throwsA(isA<FullBackupException>()));
    tables['expense_records']!.single['ledger_id'] = 99;
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
    tables['expense_records']!.single['ledger_id'] = 1;
    tables['users']!.add({'id':2,'username':'其他用户','cloud_uid':'other_test'});
    tables['asset_accounts']!.single['user_id'] = 2;
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
  test('重复退款事件和导入key被拒绝，防止重复扣款',() {
    tables['refund_events']!.add({...tables['refund_events']!.single,'id':2});
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
    tables['refund_events']!.removeLast();
    tables['expense_records']!.add({...tables['expense_records']!.single,'id':2,'cloud_id':'other_record'});
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
  test('非法退款金额和未知设置拒绝恢复',() {
    tables['refund_sources']!.single['refund_cents'] = 10001;
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
    tables['refund_sources']!.single['refund_cents'] = 3000;
    expect(() => validate(snapshot(tables,settings:{'auth_token':'must not restore'})),
      throwsA(isA<FullBackupException>()));
    expect(() => validate(snapshot(tables,settings:{'current_ledger_id':99})),
      throwsA(isA<FullBackupException>()));
  });
  test('被篡改的待核对快照不能引用另一用户的数据',() {
    tables['users']!.add({'id':2,'username':'其他用户','cloud_uid':'other_test'});
    tables['ledgers']!.add({'id':2,'name':'他人账本','is_default':1,'cloud_id':'other_ledger','user_id':2});
    tables['import_reviews']!.add({'id':1,'user_id':1,'source':'微信','row_key':'review1',
      'reason':'待核对','payload':jsonEncode({'file_name':'微信.csv','original':{'金额':'100'},'ledger_id':2,'account_id':null,
        'expense_category_id':1,'income_category_id':2,'candidate':null}),
      'status':'pending','created_at':'2026-10-14T12:00:00.000','record_id':null});
    schema = testSchema(tables);
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
  test('导入拒绝非JSON数据对象和不完整外层结构',() {
    final value = snapshot(tables).toJson();
    value.remove('sequences');
    expect(() => FullBackupSnapshot.fromJson(value),throwsA(isA<FullBackupException>()));
  });
  test('旧账单空user_id仍按账本归属验证核对记录',() {
    tables['expense_records']!.single['user_id'] = null;
    validate(snapshot(tables));
    tables['users']!.add({'id':2,'username':'其他用户','cloud_uid':'other_test'});
    tables['ledgers']!.add({'id':2,'name':'他人账本','is_default':1,'cloud_id':'other_ledger','user_id':2});
    tables['categories']!.addAll([
      {'id':3,'name':'其他支出','type':'expense','parent_id':null,'user_id':2},
      {'id':4,'name':'其他收入','type':'income','parent_id':null,'user_id':2}]);
    tables['import_reviews']!.add({'id':1,'user_id':2,'source':'微信','row_key':'legacy_cross_owner',
      'reason':'待核对','payload':jsonEncode({'file_name':'微信.csv','original':{'金额':'100'},'ledger_id':2,
        'account_id':null,'expense_category_id':3,'income_category_id':4,'candidate':null}),
      'status':'resolved','created_at':'2026-10-14T12:00:00.000','record_id':1});
    schema = testSchema(tables);
    // A TEXT type inferred from the null fixture is replaced with the actual
    // INTEGER column used by SQLite for nullable legacy ownership.
    schema['expense_records'] = schema['expense_records']!.map((column) => column.name == 'user_id'
      ? const BackupColumn('user_id','INTEGER') : column).toList();
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
  test('已删除空账本或分类的固定收支仍完整保存，存在目标必须同用户',() {
    tables['recurring_bills']!.add({'id':1,'user_id':1,'title':'房租','type':'expense','amount_cents':100000,
      'ledger_id':99,'category_id':99,'asset_account_id':null,'day_of_month':1,
      'start_date':'2026-10-01T00:00:00.000','active_from':'2026-10-01T00:00:00.000',
      'enabled':1,'note':null,'deleted_at':null,'created_at':'2026-10-01T00:00:00.000',
      'updated_at':'2026-10-01T00:00:00.000'});
    schema = testSchema(tables);
    validate(snapshot(tables));
    tables['users']!.add({'id':2,'username':'其他用户','cloud_uid':'other_test'});
    tables['ledgers']!.add({'id':99,'name':'他人账本','is_default':1,'cloud_id':'other_ledger','user_id':2});
    expect(() => validate(snapshot(tables)),throwsA(isA<FullBackupException>()));
  });
}
