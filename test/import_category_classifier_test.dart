import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/category.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/services/bill_category_classifier.dart';
import 'package:my_accounting_app/services/bill_csv_service.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';
import 'dart:convert';

void main() {
  late List<Category> categories;
  setUp(() {
    categories = [
      Category(id: 1, userId: 7, name: '餐饮', type: 'expense'),
      Category(id: 2, userId: 7, name: '交通', type: 'expense'),
      Category(id: 3, userId: 7, name: '购物', type: 'expense'),
      Category(id: 4, userId: 7, name: '住房', type: 'expense'),
      Category(id: 5, userId: 7, name: '娱乐', type: 'expense'),
      Category(id: 6, userId: 7, name: '其他支出', type: 'expense'),
      Category(id: 7, userId: 7, name: '工资', type: 'income'),
      Category(id: 8, userId: 7, name: '奖金', type: 'income'),
      Category(id: 9, userId: 7, name: '其他收入', type: 'income'),
    ];
  });
  Category? classify(String type, {String source = '', String title = '',
      String merchant = '', int? preserved, int? override}) =>
      BillCategoryClassifier.choose(categories: categories, type: type,
          originalCategory: source, title: title, merchant: merchant,
          preservedCategoryId: preserved, overrideCategoryId: override);

  test('Unknown expenses and income use separate other categories', () {
    expect(classify('expense', merchant: '未识别商户')?.id, 6);
    expect(classify('income', source: '转账', title: '朋友转给我')?.id, 9);
    expect(classify('income', source: '微信红包')?.id, 9);
  });
  test('Alipay classification takes precedence over merchant text', () {
    expect(classify('expense', source: '餐饮美食', title: '商品', merchant: '某超市')?.id, 1);
    expect(classify('expense', source: '交通出行', title: '订单')?.id, 2);
    expect(classify('expense', source: '生活日用')?.id, 3);
  });
  test('WeChat generic merchant type uses product and merchant evidence', () {
    expect(classify('expense', source: '商户消费', title: '午餐')?.id, 1);
    expect(classify('expense', source: '商户消费', merchant: '某某地铁')?.id, 2);
    expect(classify('expense', title: '两包牛奶')?.id, 3);
    expect(classify('expense', title: '视频会员续费')?.id, 5);
    expect(classify('expense', title: '十月房租')?.id, 4);
  });
  test('Clear income evidence does not reuse expense categories', () {
    expect(classify('income', title: '十月工资')?.id, 7);
    expect(classify('income', title: '年终奖')?.id, 8);
    expect(classify('income', title: '咖啡店转账')?.id, 9);
  });
  test('Existing exported and explicit override categories are preserved', () {
    expect(classify('expense', preserved: 5, title: '牛奶')?.id, 5);
    expect(classify('expense', override: 4, title: '牛奶')?.id, 4);
    expect(classify('expense', preserved: 5, override: 4, title: '牛奶')?.id, 5);
    expect(classify('expense', preserved: 7, title: '牛奶')?.id, 3);
    expect(classify('income', override: 3, title: '工资')?.id, 7);
  });
  test('Exact custom source category is supported', () {
    categories.add(Category(id: 20, userId: 7, name: '宠物', type: 'expense'));
    expect(classify('expense', source: '宠物', title: '订单')?.id, 20);
    expect(classify('expense', source: '宠物用品', title: '订单')?.id, 6);
  });
  test('Short category substrings do not guess unrelated titles', () {
    categories.add(Category(id: 21, userId: 7, name: '车', type: 'expense'));
    expect(classify('expense', title: '汽车模型收藏')?.id, 6);
    expect(classify('expense', title: '购物车结算')?.id, 6);
    expect(classify('expense', title: '银行转账')?.id, 6);
  });
  test('Generic source other still uses the explicit income/expense fallback', () {
    categories.add(Category(id: 24, userId: 7, name: '其他', type: 'expense'));
    expect(classify('expense', source: '其他', title: '订单')?.id, 6);
  });
  test('Unavailable known category falls back rather than first category', () {
    expect(classify('expense', source: '医疗健康', merchant: '某医院')?.id, 6);
    categories.add(Category(id: 22, userId: 7, name: '医疗健康', type: 'expense'));
    expect(classify('expense', merchant: '某医院')?.id, 22);
  });
  test('Competing keyword groups stay in other', () {
    expect(classify('expense', title: '房租和午餐一起支付')?.id, 6);
    expect(classify('income', title: '工资与奖金合并到账')?.id, 9);
  });
  test('Refund title is not automatically considered salary income', () {
    expect(classify('income', title: '工资退款')?.id, 9);
    expect(classify('income', title: '购物退款')?.id, 9);
  });
  test('Missing other returns null so callers can ensure a fallback', () {
    categories.removeWhere((c) => c.name == '其他支出');
    expect(classify('expense', title: '无法识别的交易'), isNull);
    expect(classify('income', title: '无法识别的交易')?.id, 9);
    expect(classify('ignore', title: '牛奶'), isNull);
  });
  test('Category aliases match available names without requiring new categories', () {
    categories.removeWhere((c) => c.id == 1);
    categories.add(Category(id: 23, userId: 7, name: '饮食', type: 'expense'));
    expect(classify('expense', source: '餐饮美食')?.id, 23);
    expect(classify('expense', title: '午餐')?.id, 23);
  });
  test('Export retains category name without changing old field positions', () {
    final record = ExpenseRecord(id: 1, userId: 7, ledgerId: 1,
      type: 'expense', amount: 7, categoryId: 3,
      date: DateTime(2026, 10, 13), title: '牛奶', importKey: '微信:ORDER1');
    final csv = BillCsvService(DatabaseHelper()).encode([record], categoryNames: {3: '购物'});
    final table = BillFileReader.read('账单.csv', utf8.encode(csv)).single;
    expect(table.source, '本软件');
    expect(table.headers[10], '分类名称');
    expect(table.rows.single[4], '3');
    expect(table.rows.single[9], '微信:ORDER1');
    expect(table.rows.single[10], '购物');
    expect(table.headers.skip(11), ['原付款金额(分)', '累计退款金额(分)', '退款计算依据']);
    expect(table.rows.single.skip(11), ['', '', '']);
  });
}
