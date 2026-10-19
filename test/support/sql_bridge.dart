import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';

/// Integration-only adapter to Node's native SQLite engine. Production uses sqflite.
class SqlBridge implements Database, Transaction {
  final String id;
  final Uri endpoint;
  final String token;
  final HttpClient client = HttpClient();
  SqlBridge(this.id, this.endpoint, this.token);
  Future<dynamic> _call(String sql, List<Object?>? args, String mode) async {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set('X-Test-Token', token);
    request.write(
      jsonEncode({'id': id, 'sql': sql, 'args': args ?? [], 'mode': mode}),
    );
    final response = await request.close();
    final body =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (response.statusCode != 200) throw StateError(body['error'].toString());
    return body['result'];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await _call(sql, arguments, 'execute');
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => (await _call(sql, arguments, 'query') as List)
      .map((r) => Map<String, Object?>.from(r as Map))
      .toList();
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async =>
      await _call(sql, arguments, 'insert') as int;
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async =>
      await _call(sql, arguments, 'update') as int;
  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async =>
      await _call(sql, arguments, 'update') as int;
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => rawQuery(
    'SELECT ${distinct == true ? 'DISTINCT ' : ''}${columns?.join(',') ?? '*'} FROM "$table"${where == null ? '' : ' WHERE $where'}${groupBy == null ? '' : ' GROUP BY $groupBy'}${having == null ? '' : ' HAVING $having'}${orderBy == null ? '' : ' ORDER BY $orderBy'}${limit == null ? '' : ' LIMIT $limit'}${offset == null ? '' : ' OFFSET $offset'}',
    whereArgs,
  );
  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    final names = values.keys.toList();
    return rawInsert(
      'INSERT ${conflictAlgorithm == ConflictAlgorithm.replace ? 'OR REPLACE ' : ''}INTO "$table" (${names.map((n) => '"$n"').join(',')}) VALUES (${List.filled(names.length, '?').join(',')})',
      names.map((n) => values[n]).toList(),
    );
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => rawUpdate(
    'UPDATE "$table" SET ${values.keys.map((k) => '"$k"=?').join(',')}${where == null ? '' : ' WHERE $where'}',
    [...values.values, ...?whereArgs],
  );
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      rawDelete(
        'DELETE FROM "$table"${where == null ? '' : ' WHERE $where'}',
        whereArgs,
      );
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    await execute('BEGIN IMMEDIATE');
    try {
      final result = await action(this);
      await execute('COMMIT');
      return result;
    } catch (_) {
      await execute('ROLLBACK');
      rethrow;
    }
  }

  Future<int> getVersion() async =>
      (await rawQuery('PRAGMA user_version')).single.values.single as int;
  @override
  Future<void> close() async {
    await _call('', [], 'close');
    client.close(force: true);
  }

  @override
  bool get isOpen => true;
  @override
  Database get database => this;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
