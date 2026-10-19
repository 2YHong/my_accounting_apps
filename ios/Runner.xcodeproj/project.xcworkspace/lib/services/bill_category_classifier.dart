import '../database/database_helper.dart';
import '../models/category.dart';

/// Local, conservative rules shared by imported bills and voice drafts.
/// Callers pass only the current user's categories; no merchant data is sent out.
class BillCategoryClassifier {
  static String _clean(String value) => value
      .replaceAll(RegExp(r'[\s\uFEFF\u200B]'), '')
      .trim();

  static String fallbackName(String type) =>
      type == 'income' ? '其他收入' : '其他支出';

  static const _expenseRules = <_CategoryRule>[
    _CategoryRule(
      ['餐饮', '饮食', '餐饮美食', '吃喝', '餐饮食品'],
      ['餐饮美食', '餐饮', '餐饮消费', '美食', '餐饮食品'],
      ['午餐', '早餐', '晚餐', '夜宵', '外卖', '餐厅', '饭店', '餐馆',
        '食堂', '快餐', '火锅', '烧烤', '奶茶', '咖啡', '汉堡', '肯德基', '麦当劳'],
    ),
    _CategoryRule(
      ['交通', '交通出行', '出行', '交通费'],
      ['交通出行', '交通', '公共交通', '交通运输'],
      ['地铁', '公交', '出租车', '打车', '网约车', '高铁', '火车票', '机票',
        '飞机票', '停车费', '停车场', '高速通行', '过路费', '滴滴出行', '加油站'],
    ),
    _CategoryRule(
      ['住房', '居住', '房屋', '住房物业', '生活缴费'],
      ['住房物业', '住房', '生活缴费', '物业管理'],
      ['房租', '房贷', '物业费', '水费', '电费', '燃气费', '煤气费', '供暖费'],
    ),
    _CategoryRule(
      ['购物', '日用品', '日常购物', '生活用品'],
      ['购物', '生活日用', '服饰装扮', '数码电器', '家居家装', '食品酒水',
        '日用百货', '母婴用品', '百货', '超市'],
      ['牛奶', '酸奶', '纸巾', '洗衣液', '洗发水', '牙膏', '牙刷', '日用品',
        '日用百货', '便利店', '超市', '服装', '衣服', '鞋子', '淘宝', '京东',
        '拼多多', '天猫'],
    ),
    _CategoryRule(
      ['娱乐', '休闲娱乐', '休闲', '订阅', '会员订阅'],
      ['休闲娱乐', '文化休闲', '娱乐', '游戏娱乐'],
      ['电影票', '电影院', '演唱会', '游戏充值', '视频会员', '视频订阅',
        '腾讯视频', '爱奇艺', '优酷会员', '音乐会员', '网易云音乐会员'],
    ),
    _CategoryRule(
      ['医疗', '医疗健康', '健康', '医药'],
      ['医疗健康', '医疗', '医药卫生'],
      ['医院', '诊所', '药店', '挂号费', '医疗费', '体检费', '医药费'],
    ),
    _CategoryRule(
      ['教育', '学习', '教育培训', '学习教育'],
      ['教育培训', '教育', '学习', '文化教育'],
      ['学费', '培训费', '课程费', '书店', '教材', '考试费'],
    ),
    _CategoryRule(
      ['通讯', '通信', '通讯费', '通信费', '话费'],
      ['通讯物流', '通讯', '通信', '通信服务'],
      ['话费', '手机月租', '手机套餐', '宽带费', '中国移动', '中国联通', '中国电信'],
    ),
  ];

  static const _incomeRules = <_CategoryRule>[
    _CategoryRule(
      ['工资', '薪资', '工资收入', '薪酬'],
      ['工资', '工资收入', '薪资', '薪酬'],
      ['工资', '薪资', '薪酬', '薪水', '工资代发', '代发工资'],
    ),
    _CategoryRule(
      ['奖金', '奖金收入'],
      ['奖金', '奖金收入'],
      ['奖金', '年终奖', '绩效奖', '季度奖'],
    ),
    _CategoryRule(
      ['利息', '理财', '投资收益', '理财收益'],
      ['投资收益', '理财收益', '利息收入'],
      ['存款利息', '利息收入', '理财收益', '分红收入', '股息'],
    ),
    _CategoryRule(
      ['兼职', '兼职收入'],
      ['兼职', '兼职收入'],
      ['兼职工资', '兼职收入', '稿费'],
    ),
  ];

  /// Preserves a valid exported category, then an explicit manual override.
  /// Conflicting keyword groups or unavailable target categories use "other".
  static Category? choose({
    required List<Category> categories,
    required String type,
    String originalCategory = '',
    String title = '',
    String merchant = '',
    String description = '',
    int? preservedCategoryId,
    int? overrideCategoryId,
  }) {
    if (type != 'expense' && type != 'income') return null;
    final available = categories.where((c) => c.type == type && c.id != null).toList();
    Category? withId(int? id) => id == null ? null
        : available.where((c) => c.id == id).firstOrNull;
    final preserved = withId(preservedCategoryId);
    if (preserved != null) return preserved;
    final overridden = withId(overrideCategoryId);
    if (overridden != null) return overridden;
    final fallback = available.where((c) => _clean(c.name) == fallbackName(type)).firstOrNull;
    final original = _clean(originalCategory);
    if (original.isNotEmpty && !['其他', '其它', '未分类', '未知', '不详'].contains(original)) {
      final exact = available.where((c) => _clean(c.name) == original).firstOrNull;
      if (exact != null) return exact;
    }
    final rules = type == 'income' ? _incomeRules : _expenseRules;
    Category? target(_CategoryRule rule) {
      for (final name in rule.categoryNames) {
        final match = available.where((c) => _clean(c.name) == name).firstOrNull;
        if (match != null) return match;
      }
      return null;
    }
    // Source classifications are stronger evidence than merchant/product text.
    for (final rule in rules) {
      if (rule.sourceNames.contains(original)) return target(rule) ?? fallback;
    }
    final fields = [title, merchant, description].map(_clean).where((v) => v.isNotEmpty).toList();
    // Refund titles are not salary simply because the original bill
    // mentions salary. The amount and direction still require separate review.
    if (type == 'income' && fields.any((v) => RegExp(r'退款|退回|退还').hasMatch(v))) {
      return fallback;
    }
    final matched = rules.where((rule) => fields.any((field) =>
        rule.keywords.any(field.contains))).toList();
    if (matched.length == 1) return target(matched.single) ?? fallback;
    return fallback;
  }

  /// Adds only missing fallback categories inside one transaction. Existing
  /// categories (including custom parents/colors) are preserved as they are.
  static Future<List<Category>> ensureFallbacks(DatabaseHelper db, int userId) async {
    final database = await db.database;
    return database.transaction((txn) async {
      final users = await txn.query('users', columns: ['id'],
          where: 'id = ?', whereArgs: [userId], limit: 1);
      if (users.isEmpty) throw const FormatException('当前用户不存在，请重新打开导入页面');
      final categories = (await txn.query('categories',
          where: 'user_id = ?', whereArgs: [userId],
          orderBy: 'is_system DESC, name ASC'))
          .map((row) => Category.fromMap(row)).toList();
      for (final type in ['expense', 'income']) {
        final name = fallbackName(type);
        if (categories.any((c) => c.type == type && _clean(c.name) == name)) continue;
        final category = Category(name: name, type: type, userId: userId, icon: 'other');
        category.id = await txn.insert('categories', category.toMap()..remove('id'));
        categories.add(category);
      }
      return categories;
    });
  }
}

class _CategoryRule {
  final List<String> categoryNames;
  final List<String> sourceNames;
  final List<String> keywords;
  const _CategoryRule(this.categoryNames, this.sourceNames, this.keywords);
}
