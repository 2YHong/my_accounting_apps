import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/models/user.dart';
import 'support/sql_bridge.dart';

void main() {
  final enabled = Platform.environment.containsKey('SQL_BRIDGE_URL');
  Future<SqlBridge> fixture(String id) async {
    final db = SqlBridge(
      id,
      Uri.parse(Platform.environment['SQL_BRIDGE_URL']!),
      Platform.environment['SQL_BRIDGE_TOKEN']!,
    );
    addTearDown(db.close);
    await db.insert('users', {
      'id': 1,
      'username': '默认用户',
      'email': 'owner@example.invalid',
      'cloud_uid': 'existing-cloud-binding',
      'local_password_hash': 'unchanged-hash',
      'avatar_path': 'existing-avatar',
    });
    return db;
  }

  test(
    'nickname survives a fresh read using the existing users schema',
    () async {
      final db = await fixture('nickname_persist');
      final before = (await db.query('users')).single;
      expect(before.containsKey('created_at'), isFalse);
      await DatabaseHelper.forTesting(db).updateUsername(1, '  🌻小明  ');
      final reloaded = await DatabaseHelper.forTesting(db).getCurrentUser();
      expect(reloaded.username, '🌻小明');
      final after = (await db.query('users')).single;
      for (final key in before.keys.where((key) => key != 'username')) {
        expect(after[key], before[key], reason: 'nickname must preserve $key');
      }
    },
    skip: !enabled,
  );

  test(
    'legacy updateUser no longer writes a nonexistent created_at column',
    () async {
      final db = await fixture('nickname_legacy');
      final helper = DatabaseHelper.forTesting(db);
      final user = await helper.getCurrentUser();
      user.username = '原接口更新';
      user.createdAt = DateTime(2026, 10, 19);
      expect(await helper.updateUser(user), 1);
      expect((await helper.getCurrentUser()).username, '原接口更新');
      expect(
        (await helper.getCurrentUser()).cloudUid,
        'existing-cloud-binding',
      );
    },
    skip: !enabled,
  );

  test(
    'missing user and blank nickname fail without changing the stored user',
    () async {
      final db = await fixture('nickname_rejected');
      final helper = DatabaseHelper.forTesting(db);
      await expectLater(helper.updateUsername(999, '不存在'), throwsStateError);
      await expectLater(helper.updateUsername(1, '  '), throwsArgumentError);
      expect((await helper.getCurrentUser()).username, '默认用户');
    },
    skip: !enabled,
  );

  test(
    'SQLite rejects a failed rename without changing the previous nickname',
    () async {
      final db = await fixture('nickname_sql_failure');
      await db.execute("""
      CREATE TRIGGER reject_nickname BEFORE UPDATE OF username ON users
      BEGIN SELECT RAISE(ABORT, 'simulated write rejection'); END
    """);
      await expectLater(
        DatabaseHelper.forTesting(db).updateUsername(1, '不能保存'),
        throwsStateError,
      );
      expect(
        (await DatabaseHelper.forTesting(db).getCurrentUser()).username,
        '默认用户',
      );
    },
    skip: !enabled,
  );

  test(
    'user serialization only contains columns present in the users table',
    () {
      final map = User(username: '昵称', createdAt: DateTime(2026)).toMap();
      expect(map.keys.toSet(), {
        'id',
        'username',
        'email',
        'avatar_path',
        'local_password_hash',
        'cloud_uid',
      });
    },
  );
}
