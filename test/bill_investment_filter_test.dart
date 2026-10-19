import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/bill_investment_filter.dart';

void main() {
  test('明确投资分类同时排除本金交易和相关收益', () {
    for (final category in ['金融理财', '基金投资', '股票投资', '投资收益', '基金分红', '理财收益']) {
      expect(BillInvestmentFilter.isInvestment(category: category, title: '交易成功'), isTrue,
        reason: category);
    }
  });
  test('交易说明能识别申购赎回定投及收益', () {
    for (final title in ['基金申购', '基金赎回到账', 'ETF定投', '股票买入', '债券卖出',
      '理财产品本金退回', '股票分红', '基金申购退款', '基金交易手续费']) {
      expect(BillInvestmentFilter.isInvestment(title: title), isTrue, reason: title);
    }
  });
  test('余额宝零钱通及银证流水均排除', () {
    for (final title in ['余额宝转入', '余额宝收益发放', '零钱通转出', '理财通赎回',
      '银证转账', '证券账户提现']) {
      expect(BillInvestmentFilter.isInvestment(title: title), isTrue, reason: title);
    }
  });
  test('明确金融机构配合交易动作才能排除', () {
    expect(BillInvestmentFilter.isInvestment(counterparty: '某某基金管理有限公司', title: '申购'), isTrue);
    expect(BillInvestmentFilter.isInvestment(counterparty: '某某证券股份有限公司', title: '股票交易'), isTrue);
    expect(BillInvestmentFilter.isInvestment(counterparty: '某某基金管理有限公司', title: '工资发放'), isFalse);
  });
  test('捐款和投资教育不会按金融关键字误排', () {
    expect(BillInvestmentFilter.isInvestment(counterparty: '某某基金会', title: '捐赠'), isFalse);
    expect(BillInvestmentFilter.isInvestment(category: '金融理财', title: '基金投资课程'), isFalse);
    expect(BillInvestmentFilter.isInvestment(title: '股票投资入门书籍'), isFalse);
    expect(BillInvestmentFilter.isInvestment(title: '慈善基金认购捐款'), isFalse);
    expect(BillInvestmentFilter.isInvestment(category: '金融理财', title: '偿还贷款本金'), isFalse);
  });
  test('不明确用途及普通金融生活收支保留', () {
    for (final title in ['购买黄金首饰', '存款利息', '贷款利息', '房贷还款', '普通转账', '股票主题手机壳', '牛奶']) {
      expect(BillInvestmentFilter.isInvestment(category: '金融服务', title: title), isFalse, reason: title);
    }
  });
  test('空格与英文ETF大小写不影响明确交易识别', () {
    expect(BillInvestmentFilter.isInvestment(title: 'e t f 定 投'), isTrue);
    expect(BillInvestmentFilter.isInvestment(description: '基金 赎回 成功'), isTrue);
    expect(BillInvestmentFilter.isInvestment(), isFalse);
  });
}
