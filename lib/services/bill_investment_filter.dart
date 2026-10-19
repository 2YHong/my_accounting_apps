/// Excludes explicit investment cash flows from daily accounting imports.
/// A financial word alone is not enough to discard an ordinary purchase.
class BillInvestmentFilter {
  static const _categories = {
    '投资', '投资理财', '金融理财', '证券投资', '股票投资', '基金投资',
    '基金理财', '理财', '股票', '证券', '基金', '债券投资', '期货投资',
    '投资收益', '理财收益', '基金收益', '股票收益', '基金分红', '股票分红', '股息收入',
  };
  static final _ordinary = RegExp(
    r'基金会|公益|慈善|捐款|捐赠|助学|救助|书籍|教材|教程|课程|培训|讲座|投教|咨询费|投资入门|投资指南|信用卡还款|房贷|车贷|贷款|还贷|借款');
  static final _subject = RegExp(r'基金|股票|证券|理财|债券|期货|ETF|投资', caseSensitive: false);
  static final _operation = RegExp(r'申购|赎回|认购|定投|买入|卖出|买卖|分红|股息|派息|收益|本金|手续费|(?:基金|股票|证券|债券|期货|ETF)交易', caseSensitive: false);
  static final _provider = RegExp(r'基金管理|证券公司|证券股份|证券有限|蚂蚁财富');
  static final _providerOperation = RegExp(r'申购|赎回|认购|定投|买入|卖出|分红|股息|派息|手续费');
  static final _wallet = RegExp(r'余额宝|零钱通|理财通');
  static final _walletOperation = RegExp(r'转入|转出|存入|取出|申购|赎回|收益|分红|本金|买入|卖出|充值|提现|划转');
  static final _securitiesTransfer = RegExp(r'银证转账|银证转入|银证转出|证券账户(?:转入|转出|充值|提现)|基金账户(?:充值|提现)');

  static String _compact(String value) => value.replaceAll(RegExp(r'\s'), '');

  static bool isInvestment({String category = '', String title = '',
    String description = '', String counterparty = ''}) {
    final fields = [category, title, description].map(_compact).toList();
    final merchant = _compact(counterparty);
    if (_ordinary.hasMatch([...fields, merchant].join(' '))) return false;
    if (_categories.contains(fields.first)) return true;
    for (final field in fields) {
      if (_securitiesTransfer.hasMatch(field) ||
          (_subject.hasMatch(field) && _operation.hasMatch(field)) ||
          (_wallet.hasMatch(field) && _walletOperation.hasMatch(field))) {
        return true;
      }
    }
    final transaction = fields.skip(1).join(' ');
    return (_provider.hasMatch(merchant) && _providerOperation.hasMatch(transaction)) ||
      (_wallet.hasMatch(merchant) && _walletOperation.hasMatch(transaction));
  }
}
