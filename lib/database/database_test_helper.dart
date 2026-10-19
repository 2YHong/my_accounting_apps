import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';
import '../models/user.dart';
import '../models/ledger.dart';
import '../models/category.dart';
import '../models/asset_account.dart';
import '../models/budget.dart';
import '../models/tag.dart';
import '../models/expense_record.dart';

class DatabaseTestHelper {
  final DatabaseHelper dbHelper = DatabaseHelper();

  Future<void> runAllTests() async {
    print('🧪 开始数据库集成测试...\n');

    // 获取数据库连接，这会触发建表
    final Database db = await dbHelper.database;
    print('✅ 1. 数据库连接成功，所有表应已创建。\n');

    // 测试1: 插入一个测试用户
    print('📝 测试1: 插入用户...');
    final User testUser = User(username: '测试用户', email: 'test@example.com');
    // 注意：这里需要你先在 DatabaseHelper 中添加 insertUser 方法
    // 我们先打印信息，方法稍后实现
    print('   测试用户对象创建: ${testUser.username}');
    
    // 测试2: 插入系统分类
    print('\n📝 测试2: 插入预设分类...');
    final List<Category> systemCategories = [
      Category(name: '餐饮', type: 'expense', icon: '🍔', isSystem: 1),
      Category(name: '交通', type: 'expense', icon: '🚗', isSystem: 1),
      Category(name: '工资', type: 'income', icon: '💰', isSystem: 1),
      Category(name: '投资理财', type: 'ignore', icon: '📈', isSystem: 1),
    ];
    for (var category in systemCategories) {
      print('   ${category.icon} ${category.name} (${category.type})');
    }

    // 测试3: 插入一个默认账本
    print('\n📝 测试3: 插入默认账本...');
    final Ledger defaultLedger = Ledger(name: '默认账本', isDefault: 1, icon: '🏠');
    print('   账本: ${defaultLedger.name}');

    // 测试4: 插入资产账户
    print('\n📝 测试4: 插入资产账户...');
    final AssetAccount alipayAccount = AssetAccount(
      name: '支付宝',
      type: 'digital',
      icon: '📱',
      balance: 5000.0,
    );
    print('   账户: ${alipayAccount.name} 余额: ¥${alipayAccount.balance}');

    // 测试5: 插入一条测试账单
    print('\n📝 测试5: 插入测试账单记录...');
    // 这里假设分类和账本的ID为1（因为首次插入）
    final ExpenseRecord testRecord = ExpenseRecord(
      ledgerId: 1,
      type: 'expense',
      amount: 25.0,
      categoryId: 1, // 假设是“餐饮”分类
      assetAccountId: 1, // 假设是“支付宝”账户
      date: DateTime.now(),
      note: '测试午餐',
    );
    print('   账单: ${testRecord.note} 金额: ¥${testRecord.amount}');

    // 测试6: 查询并打印所有表的数据量
    print('\n📊 测试6: 查询各表记录数...');
    final tables = ['users', 'ledgers', 'categories', 'asset_accounts', 'expense_records'];
    for (String table in tables) {
      try {
        final List<Map> countResult = await db.rawQuery('SELECT COUNT(*) as count FROM $table');
        print('   $table: ${countResult.first['count']} 条记录');
      } catch (e) {
        print('   $table: 查询失败 - $e');
      }
    }

    print('\n🎉 所有测试步骤描述完成！');
    print('⚠️  注意：以上仅为测试流程描述。要实际执行，需要在 DatabaseHelper 中实现对应的插入方法。');
    print('   建议你优先实现这些方法，或直接进入UI开发，在实际需要时再补全数据操作。');
  }
}