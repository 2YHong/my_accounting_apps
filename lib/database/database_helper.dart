import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../sync/local_sync_schema.dart';
import '../services/account_balances.dart';
import '../services/asset_notifications.dart';
import '../models/expense_record.dart';
import '../models/asset_account.dart';
import '../models/user.dart';
import '../models/ledger.dart';
import '../models/category.dart';
import '../models/tag.dart';
import '../models/budget.dart';
import '../models/settings_manager.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();

  /// Isolated databases for native SQLite integration tests.
  DatabaseHelper.forTesting(Database db) : _injectedDatabase = db;
  final Database? _injectedDatabase;
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal() : _injectedDatabase = null;

  static Database? _database;

  Future<Database> get database async {
    if (_injectedDatabase != null) return _injectedDatabase;
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'my_money.db');
    return await openDatabase(
      path,
      version: 10,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE categories ADD COLUMN color TEXT');
          await _seedRecordCategories(db);
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE expense_records ADD COLUMN import_key TEXT');
          await db.execute('CREATE UNIQUE INDEX record_import_key ON expense_records(user_id, import_key)');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE expense_records ADD COLUMN title TEXT');
        }
        if (oldVersion < 5) await _createImportReviews(db);
        if (oldVersion < 6) await _createRecurringBills(db);
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE expense_records ADD COLUMN refund_gross_cents INTEGER');
          await db.execute('ALTER TABLE expense_records ADD COLUMN refund_total_cents INTEGER');
          await db.execute('ALTER TABLE expense_records ADD COLUMN refund_basis TEXT');
          await _createRefundAudit(db);
        }
        if (oldVersion < 9) await LocalSyncSchema.install(db);
        if (oldVersion < 10) await AccountBalances.migrate(db);
      },
      onCreate: _onCreate,
    );
  }

  Future<void> _createImportReviews(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS import_reviews (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        source TEXT NOT NULL,
        row_key TEXT NOT NULL,
        reason TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','ignored')),
        created_at TEXT NOT NULL,
        record_id INTEGER,
        UNIQUE(user_id, row_key)
      )
    ''');
  }

  Future<void> _createRefundAudit(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS refund_sources (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      import_key TEXT NOT NULL,
      gross_cents INTEGER NOT NULL CHECK(gross_cents > 0),
      refund_cents INTEGER NOT NULL CHECK(refund_cents >= 0 AND refund_cents <= gross_cents),
      basis TEXT NOT NULL CHECK(basis IN ('none','cumulative','events','export')),
      snapshot_at TEXT,
      record_id INTEGER,
      manually_edited INTEGER NOT NULL DEFAULT 0 CHECK(manually_edited IN (0,1)),
      version INTEGER NOT NULL DEFAULT 1,
      original_json TEXT NOT NULL,
      UNIQUE(user_id, import_key)
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS refund_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      source TEXT NOT NULL,
      refund_id TEXT NOT NULL,
      import_key TEXT NOT NULL,
      amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
      refunded_at TEXT,
      original_json TEXT NOT NULL,
      UNIQUE(user_id, source, refund_id)
    )''');
  }

  Future<void> _createRecurringBills(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recurring_bills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('expense','income')),
        amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
        ledger_id INTEGER NOT NULL,
        category_id INTEGER NOT NULL,
        asset_account_id INTEGER,
        day_of_month INTEGER NOT NULL CHECK(day_of_month BETWEEN 1 AND 31),
        start_date TEXT NOT NULL,
        active_from TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        note TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recurring_occurrences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        rule_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        period TEXT NOT NULL,
        due_date TEXT NOT NULL,
        snapshot TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending','confirmed','skipped')),
        record_id INTEGER,
        resolution TEXT,
        resolved_at TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(rule_id, period)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS recurring_pending_user ON recurring_occurrences(user_id, status, due_date)');
  }

  Future<void> _onCreate(Database db, int version) async {


  // 1. 用户表
  await db.execute('''
    CREATE TABLE users(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL,
      email TEXT,
      avatar_path TEXT,
      local_password_hash TEXT,
      cloud_uid TEXT UNIQUE
    )
  ''');

  // 2. 账本表
  await db.execute('''
    CREATE TABLE ledgers(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      icon TEXT,
      is_default INTEGER DEFAULT 0,
      desc TEXT,
      cloud_id TEXT UNIQUE,
      user_id INTEGER,
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  // 3. 分类表
  await db.execute('''
    CREATE TABLE categories(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      type TEXT NOT NULL CHECK(type IN ('expense', 'income', 'ignore')),
      icon TEXT,
      is_system INTEGER DEFAULT 0,
      color TEXT,
      parent_id INTEGER,
      user_id INTEGER,
      FOREIGN KEY (parent_id) REFERENCES categories (id),
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  // 4. 资产账户表
  await db.execute('''
    CREATE TABLE asset_accounts(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      icon TEXT,
      balance REAL NOT NULL DEFAULT 0.0,
      balance_offset_cents INTEGER,
      card_number_last_four TEXT,
      credit_limit REAL,
      desc TEXT,
      category_id INTEGER,
      user_id INTEGER,
      FOREIGN KEY (category_id) REFERENCES categories (id),
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  // 5. 预算表
  await db.execute('''
    CREATE TABLE budgets(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ledger_id INTEGER NOT NULL,
      category_id INTEGER,
      amount REAL NOT NULL,
      cycle TEXT NOT NULL,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      cloud_id TEXT UNIQUE,
      user_id INTEGER,
      FOREIGN KEY (ledger_id) REFERENCES ledgers (id),
      FOREIGN KEY (category_id) REFERENCES categories (id),
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  // 6. 标签表
  await db.execute('''
    CREATE TABLE tags(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      color TEXT,
      user_id INTEGER,
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  // 7. 账单记录表
  await db.execute('''
    CREATE TABLE expense_records(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ledger_id INTEGER NOT NULL,
      type TEXT NOT NULL CHECK(type IN ('expense', 'income')),
      amount REAL NOT NULL,
      category_id INTEGER NOT NULL,
      asset_account_id INTEGER,
      date TEXT NOT NULL,
      note TEXT,
      title TEXT,
      import_key TEXT,
      refund_gross_cents INTEGER,
      refund_total_cents INTEGER,
      refund_basis TEXT,
      cloud_id TEXT UNIQUE,
      user_id INTEGER,
      is_synced INTEGER DEFAULT 0,
      FOREIGN KEY (ledger_id) REFERENCES ledgers (id),
      FOREIGN KEY (category_id) REFERENCES categories (id),
      FOREIGN KEY (asset_account_id) REFERENCES asset_accounts (id),
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
  ''');

  await db.execute('CREATE UNIQUE INDEX record_import_key ON expense_records(user_id, import_key)');

  // 8. 账单-标签关联表
  await db.execute('''
    CREATE TABLE record_tags(
      record_id INTEGER NOT NULL,
      tag_id INTEGER NOT NULL,
      PRIMARY KEY (record_id, tag_id),
      FOREIGN KEY (record_id) REFERENCES expense_records (id) ON DELETE CASCADE,
      FOREIGN KEY (tag_id) REFERENCES tags (id) ON DELETE CASCADE
    )
  ''');



  // ============ 在这里添加初始化数据 ============
  // 首先插入一个默认用户（因为其他表有外键约束）
  await db.insert('users', {
    'id': 1,
    'username': '默认用户',
    'email': 'default@example.com',
    'avatar_path': '',
    'local_password_hash': '',
    'cloud_uid': 'default_user_001',
  });


// 在 database_helper.dart 的 _onCreate 方法中，插入默认用户后添加：
// 插入默认账本（总账本）
await db.insert('ledgers', {
  'name': '总账本',
  'is_default': 1,
  'user_id': 1, // 关联到默认用户
});

  // 插入默认的借贷账户分类（可选）
  // 注意：这里只是示例，你也可以选择不创建默认分类
  final now = DateTime.now().toIso8601String();
  
  // 插入一些默认的系统分类（用于借贷账户的描述）
  await db.insert('categories', {
    'name': '助学贷款',
    'type': 'ignore',  // 使用 'ignore' 类型，因为这些分类只用于标记，不用于收支统计
    'icon': 'school',
    'is_system': 1,
    'user_id': 1,
  });
  
  await db.insert('categories', {
    'name': '住房贷款',
    'type': 'ignore',
    'icon': 'home',
    'is_system': 1,
    'user_id': 1,
  });
  
  await db.insert('categories', {
    'name': '消费贷款',
    'type': 'ignore',
    'icon': 'shopping_cart',
    'is_system': 1,
    'user_id': 1,
  });
  
  await db.insert('categories', {
    'name': '汽车贷款',
    'type': 'ignore',
    'icon': 'directions_car',
    'is_system': 1,
    'user_id': 1,
  });
  


  await _createImportReviews(db);
  await _createRecurringBills(db);
  await _createRefundAudit(db);
  await _seedRecordCategories(db);
  await LocalSyncSchema.install(db);
  print('所有数据库表创建成功！');
  print('✅ 已插入默认用户和示例借贷账户');
}

  Future<void> _seedRecordCategories(DatabaseExecutor db) async {
    final users = await db.query('users', columns: ['id']);
    for (final user in users) {
      for (final type in ['expense', 'income']) {
        final existing = await db.query('categories',
          where: 'user_id = ? AND type = ?', whereArgs: [user['id'], type], limit: 1);
        if (existing.isNotEmpty) continue;
        final names = type == 'expense' ? ['餐饮', '交通', '购物', '住房', '娱乐', '其他支出']
          : ['工资', '奖金', '其他收入'];
        for (final name in names) {
          await db.insert('categories', {'name': name, 'type': type, 'is_system': 1, 'user_id': user['id']});
        }
      }
    }
  }

  // Date range APIs include the whole end day, not just its midnight.
  String _endExclusive(DateTime end) => DateTime(end.year, end.month, end.day + 1).toIso8601String();

  // ============ 账单记录操作 ============

  // 添加新账单记录
  Future<int> insertRecord(ExpenseRecord record) async {
    final db = await database;
    final id = await db.insert('expense_records', record.toMap());
    notifyAssetAccountsChanged();
    return id;
  }

  // 添加这个方法 - 用于兼容旧的调用
  Future<int> insertExpenseRecord(ExpenseRecord record) async {
    return await insertRecord(record);
  }

  // 更新账单记录
  Future<int> updateRecord(ExpenseRecord record) async {
    final db = await database;
    final changed = await db.transaction((txn) async {
      final old = await txn.query('expense_records', where: 'id = ?', whereArgs: [record.id]);
      if (old.isEmpty) return 0;
      final previous = old.first;
      final map = record.toMap();
      // UI edits retain provenance even when callers were built before v7.
      for (final key in ['refund_gross_cents', 'refund_total_cents', 'refund_basis']) {
        map[key] ??= previous[key];
      }
      if (previous['amount'] != record.amount || previous['type'] != record.type) {
        await txn.rawUpdate('UPDATE refund_sources SET manually_edited = 1, version = version + 1 WHERE record_id = ?', [record.id]);
      }
      return txn.update('expense_records', map, where: 'id = ?', whereArgs: [record.id]);
    });
    notifyAssetAccountsChanged();
    return changed;
  }

  // 删除账单记录
  Future<int> deleteRecord(int id) async {
    final db = await database;
    final changed = await db.transaction((txn) async {
      await txn.rawUpdate('UPDATE refund_sources SET record_id = NULL, manually_edited = 1, version = version + 1 WHERE record_id = ?', [id]);
      await txn.delete('record_tags', where: 'record_id = ?', whereArgs: [id]);
      return txn.delete('expense_records', where: 'id = ?', whereArgs: [id]);
    });
    notifyAssetAccountsChanged();
    return changed;
  }

  // 获取所有账单记录
  Future<List<ExpenseRecord>> getAllRecords() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('expense_records');
    return List.generate(maps.length, (i) => ExpenseRecord.fromMap(maps[i]));
  }

  // 根据ID获取账单记录
  Future<ExpenseRecord?> getRecordById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'expense_records',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return ExpenseRecord.fromMap(maps.first);
    }
    return null;
  }

  // 获取指定日期范围内的账单记录（按日期倒序）
  Future<List<ExpenseRecord>> getRecordsByDateRange(
    DateTime start,
    DateTime end, {
    int? ledgerId,
    int? userId,
  }) async {
    final db = await database;

    String whereClause = 'date >= ? AND date < ?';
    List<dynamic> whereArgs = [
      start.toIso8601String(),
      _endExclusive(end),
    ];

    if (ledgerId != null) {
      whereClause += ' AND ledger_id = ?';
      whereArgs.add(ledgerId);
    }

    if (userId != null) {
      // Scope by owning ledger so older records with null user_id remain visible.
      whereClause += ' AND ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)';
      whereArgs.add(userId);
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'expense_records',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'date DESC',
    );

    return List.generate(maps.length, (i) => ExpenseRecord.fromMap(maps[i]));
  }

  // 获取所有不重复的日期（用于分组）
  Future<List<DateTime>> getDistinctDates({int? ledgerId}) async {
    final db = await database;

    String query = '''
      SELECT DISTINCT date(date) as date_only 
      FROM expense_records
      ${ledgerId != null ? 'WHERE ledger_id = ?' : ''}
      ORDER BY date_only DESC
    ''';

    List<Map<String, dynamic>> result;
    if (ledgerId != null) {
      result = await db.rawQuery(query, [ledgerId]);
    } else {
      result = await db.rawQuery(query);
    }

    return result.map((row) => DateTime.parse(row['date_only'])).toList();
  }

  // 获取分类统计
  Future<Map<String, double>> getCategorySummary(
    DateTime start,
    DateTime end, {
    int? ledgerId,
  }) async {
    final db = await database;

    String whereClause = 'date >= ? AND date < ?';
    List<dynamic> whereArgs = [
      start.toIso8601String(),
      _endExclusive(end),
    ];

    if (ledgerId != null) {
      whereClause += ' AND ledger_id = ?';
      whereArgs.add(ledgerId);
    }

    final query = '''
      SELECT c.name, SUM(e.amount) as total
      FROM expense_records e
      JOIN categories c ON e.category_id = c.id
      WHERE $whereClause
      GROUP BY c.id
      ORDER BY total DESC
    ''';

    final result = await db.rawQuery(query, whereArgs);
    
    final Map<String, double> summary = {};
    for (final row in result) {
      summary[row['name'] as String] = row['total'] as double;
    }
    
    return summary;
  }

  // 获取记录总数
  Future<int> getRecordCount() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM expense_records'),
    );
    return count ?? 0;
  }

  // 清空所有账单记录
  Future<int> clearAllRecords() async {
    final db = await database;
    final changed = await db.transaction((txn) async {
      await txn.rawUpdate('UPDATE refund_sources SET record_id = NULL, manually_edited = 1, version = version + 1 WHERE record_id IS NOT NULL');
      await txn.delete('record_tags');
      return txn.delete('expense_records');
    });
    notifyAssetAccountsChanged();
    return changed;
  }

  // 插入测试数据（仅用于开发）
  Future<void> insertTestData() async {
    final db = await database;

    // 创建一个测试记录
    final testRecord = ExpenseRecord(
      ledgerId: 1,
      type: 'expense',
      amount: 100.0,
      categoryId: 1,
      date: DateTime.now(),
      note: '测试数据',
    );

    final int id = await db.insert(
      'expense_records',
      testRecord.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    print('✅ 测试账单记录插入成功，ID: $id');
  }

  // 关闭数据库
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }

//=========================================
//===============       统计页    ==================
//统计页的统计查询方法：
// 获取指定时间范围内的收支总额
Future<Map<String, double>> getTotalByDateRange(
  DateTime start, 
  DateTime end, 
  {int? ledgerId}
) async {
  final db = await database;
  
  String whereClause = 'date >= ? AND date < ?';
  List<dynamic> whereArgs = [start.toIso8601String(), _endExclusive(end)];
  
  if (ledgerId != null) {
    whereClause += ' AND ledger_id = ?';
    whereArgs.add(ledgerId);
  }
  
  // 查询支出总额
  final expenseResult = await db.rawQuery('''
    SELECT COALESCE(SUM(amount), 0) as total 
    FROM expense_records 
    WHERE type = 'expense' AND $whereClause
  ''', whereArgs);
  
  // 查询收入总额
  final incomeResult = await db.rawQuery('''
    SELECT COALESCE(SUM(amount), 0) as total 
    FROM expense_records 
    WHERE type = 'income' AND $whereClause
  ''', whereArgs);
  
  return {
    'expense': (expenseResult.first['total'] as num).toDouble(),
    'income': (incomeResult.first['total'] as num).toDouble(),
  };
}

// 获取按日分组的支出数据（用于趋势图）
Future<List<Map<String, dynamic>>> getDailyExpenseTrend(
  DateTime start, 
  DateTime end, 
  {int? ledgerId}
) async {
  final db = await database;
  
  String query = '''
    SELECT 
      date(date) as date,
      COALESCE(SUM(amount), 0) as total
    FROM expense_records 
    WHERE type = 'expense' 
      AND date >= ? 
      AND date < ?
  ''';
  
  List<dynamic> args = [start.toIso8601String(), _endExclusive(end)];
  if (ledgerId != null) {
    query += ' AND ledger_id = ?';
    args.add(ledgerId);
  }
  
  query += ' GROUP BY date(date) ORDER BY date';
  
  return await db.rawQuery(query, args);
}

// 获取分类支出排行（用于饼图和列表）
// 获取分类支出排行（关联分类名称）
Future<List<Map<String, dynamic>>> getCategoryExpenseRanking(
  DateTime start, 
  DateTime end, 
  {int? ledgerId, int limit = 10}
) async {
  final db = await database;
  
  String query = '''
    SELECT 
      c.id as category_id,
      c.name as category_name,
      c.icon as category_icon,
      c.type as category_type,
      COUNT(*) as count,
      COALESCE(SUM(er.amount), 0) as total
    FROM expense_records er
    LEFT JOIN categories c ON er.category_id = c.id
    WHERE er.type = 'expense' 
      AND er.date >= ? 
      AND er.date < ?
  ''';
  
  List<dynamic> args = [start.toIso8601String(), _endExclusive(end)];
  if (ledgerId != null) {
    query += ' AND er.ledger_id = ?';
    args.add(ledgerId);
  }
  
  query += ' GROUP BY er.category_id ORDER BY total DESC LIMIT $limit';
  
  return await db.rawQuery(query, args);
}

//=========================================
//===============       资产页    ==================
// 获取所有资产账户
Future<List<AssetAccount>> getAllAssetAccounts({int? userId}) async {
  final rows = await AccountBalances.read(await database, userId: userId);
  return rows.map(AssetAccount.fromMap).toList();
}

Future<double> getTotalAssets({int? userId}) async =>
  (await getAllAssetAccounts(userId: userId))
    .where((a) => a.type != 'loan').fold<double>(0, (sum, a) => sum + a.balance);

Future<double> getTotalLiabilities({int? userId}) async =>
  (await getAllAssetAccounts(userId: userId))
    .where((a) => a.type == 'loan').fold<double>(0, (sum, a) => sum + a.balance);

// 更新账户余额
Future<int> updateAccountBalance(int id, double newBalance) async {
  final db = await database;
  
  final changed = await AccountBalances.calibrate(db, id, newBalance);
  notifyAssetAccountsChanged();
  return changed;
}

// 添加新账户
Future<int> insertAssetAccount(AssetAccount account) async {
  final db = await database;
  
  final int id = await db.insert(
    'asset_accounts',
    account.toMap()..['balance_offset_cents'] = account.balanceOffsetCents ?? 0,
  );
  
  print('✅ 资产账户添加成功，ID: $id');
  return id;
}

// 删除账户
Future<int> deleteAssetAccount(int id) async {
  final db = await database;
  
  return await db.delete(
    'asset_accounts',
    where: 'id = ?',
    whereArgs: [id],
  );
}

// 添加更新方法到 DatabaseHelper
// 在 database_helper.dart 中添加：
Future<int> updateAssetAccount(AssetAccount account) async {
  final db = await database;
  final changed = await db.transaction((tx) async {
    final values = account.toMap()..remove('balance')..remove('balance_offset_cents');
    final result = await tx.update('asset_accounts', values,
      where: 'id = ?', whereArgs: [account.id!]);
    if (result == 1) await AccountBalances.calibrate(tx, account.id!, account.balance);
    return result;
  });
  notifyAssetAccountsChanged();
  return changed;
}


//=========================================
//===============       我的页    ==================
// ============ 用户相关操作 ============
Future<User> getCurrentUser() async {
  final db = await database;
  final maps = await db.query('users', limit: 1);
  if (maps.isNotEmpty) {
    return User.fromMap(maps.first);
  }
  throw Exception('未找到用户');
}

Future<int> updateUser(User user) async {
  final db = await database;
  return await db.update(
    'users',
    user.toMap(),
    where: 'id = ?',
    whereArgs: [user.id],
  );
}

/// Update only the nickname, preserving login details and cloud bindings.
Future<void> updateUsername(int userId, String username) async {
  final name = username.trim();
  if (name.isEmpty) throw ArgumentError.value(username, 'username');
  final db = await database;
  final changed = await db.update(
    'users',
    {'username': name},
    where: 'id = ?',
    whereArgs: [userId],
  );
  if (changed != 1) throw StateError('未找到要修改的用户');
}

// ============ 账本相关操作 ============
Future<List<Ledger>> getAllLedgers({int? userId}) async {
  final db = await database;
  
  String whereClause = '1=1';
  List<dynamic> whereArgs = [];
  
  if (userId != null) {
    whereClause += ' AND user_id = ?';
    whereArgs.add(userId);
  }
  
  final maps = await db.query(
    'ledgers',
    where: whereClause,
    whereArgs: whereArgs,
    orderBy: 'is_default DESC, name ASC',
  );
  
  return List.generate(maps.length, (i) => Ledger.fromMap(maps[i]));
}

Future<int> insertLedger(Ledger ledger) async {
  final db = await database;
  return await db.insert('ledgers', ledger.toMap());
}

Future<int> updateLedger(Ledger ledger) async {
  final db = await database;
  return await db.update(
    'ledgers',
    ledger.toMap(),
    where: 'id = ?',
    whereArgs: [ledger.id],
  );
}

Future<int> deleteLedger(int id) async {
  final db = await database;
  return await db.delete('ledgers', where: 'id = ?', whereArgs: [id]);
}

// ============ 分类相关操作 ============
Future<List<Category>> getAllCategories({int? userId, String? type}) async {
  final db = await database;
  
  String whereClause = '1=1';
  List<dynamic> whereArgs = [];
  
  if (userId != null) {
    whereClause += ' AND user_id = ?';
    whereArgs.add(userId);
  }
  
  if (type != null) {
    whereClause += ' AND type = ?';
    whereArgs.add(type);
  }
  
  final maps = await db.query(
    'categories',
    where: whereClause,
    whereArgs: whereArgs,
    orderBy: 'is_system DESC, name ASC',
  );
  
  return List.generate(maps.length, (i) => Category.fromMap(maps[i]));
}

Future<int> insertCategory(Category category) async {
  final db = await database;
  return await db.insert('categories', category.toMap());
}

Future<int> updateCategory(Category category) async {
  final db = await database;
  return await db.update(
    'categories',
    category.toMap(),
    where: 'id = ?',
    whereArgs: [category.id],
  );
}

Future<int> deleteCategory(int id) async {
  final db = await database;
  return await db.delete('categories', where: 'id = ?', whereArgs: [id]);
}

// ============ 标签相关操作 ============
Future<List<Tag>> getAllTags({int? userId}) async {
  final db = await database;
  
  String whereClause = '1=1';
  List<dynamic> whereArgs = [];
  
  if (userId != null) {
    whereClause += ' AND user_id = ?';
    whereArgs.add(userId);
  }
  
  final maps = await db.query(
    'tags',
    where: whereClause,
    whereArgs: whereArgs,
    orderBy: 'name ASC',
  );
  
  return List.generate(maps.length, (i) => Tag.fromMap(maps[i]));
}

Future<int> insertTag(Tag tag) async {
  final db = await database;
  return await db.insert('tags', tag.toMap());
}

Future<int> updateTag(Tag tag) async {
  final db = await database;
  return await db.update(
    'tags',
    tag.toMap(),
    where: 'id = ?',
    whereArgs: [tag.id],
  );
}

Future<int> deleteTag(int id) async {
  final db = await database;
  return await db.delete('tags', where: 'id = ?', whereArgs: [id]);
}
// ============ 预算相关操作 ============
Future<int> insertBudget(Budget budget) async {
  final db = await database;
  return await db.insert('budgets', budget.toMap());
}

Future<int> updateBudget(Budget budget) async {
  final db = await database;
  return await db.update(
    'budgets',
    budget.toMap(),
    where: 'id = ?',
    whereArgs: [budget.id],
  );
}

Future<int> deleteBudget(int id) async {
  final db = await database;
  return await db.delete('budgets', where: 'id = ?', whereArgs: [id]);
}

Future<List<Budget>> getAllBudgets({int? ledgerId}) async {
  final db = await database;
  
  String whereClause = '1=1';
  List<dynamic> whereArgs = [];
  
  if (ledgerId != null) {
    whereClause += ' AND ledger_id = ?';
    whereArgs.add(ledgerId);
  }
  
  final maps = await db.query(
    'budgets',
    where: whereClause,
    whereArgs: whereArgs,
    orderBy: 'cycle, category_id',
  );
  
  return List.generate(maps.length, (i) => Budget.fromMap(maps[i]));
}

// 获取当前有效的预算（按账本和分类）
Future<Budget?> getCurrentBudget(int ledgerId, [int? categoryId]) async {
  final db = await database;
  final now = DateTime.now().toIso8601String();
  
  String whereClause = 'ledger_id = ? AND start_date <= ? AND end_date >= ?';
  List<dynamic> whereArgs = [ledgerId, now, now];
  
  if (categoryId != null) {
    whereClause += ' AND category_id = ?';
    whereArgs.add(categoryId);
  } else {
    whereClause += ' AND category_id IS NULL';
  }
  
  final maps = await db.query(
    'budgets',
    where: whereClause,
    whereArgs: whereArgs,
    limit: 1,
  );
  
  if (maps.isNotEmpty) {
    return Budget.fromMap(maps.first);
  }
  return null;
}

}
