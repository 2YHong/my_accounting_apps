class VoiceBillDraft {
  final String type;
  final String title;
  final int? amountCents;
  final DateTime date;
  final List<String> hints;
  const VoiceBillDraft({required this.type, required this.title,
    required this.amountCents, required this.date, required this.hints});
  double? get amount => amountCents == null ? null : amountCents! / 100;
}

/// Parses one short accounting sentence locally. Ambiguous money is left blank.
class VoiceBillParser {
  static const _numbers = r'0-9零〇一二两三四五六七八九十百千万';
  static final _money = RegExp(
    '(?<![${_numbers}点.负-])([$_numbers]+(?:[点.][0-9零〇一二两三四五六七八九]{1,2})?)'
    r'\s*(?:元|块(?:钱)?)(?:([0-9零〇一二两三四五六七八九])(?:角|毛))?'
    r'(?:([0-9零〇一二两三四五六七八九])分)?');

  static VoiceBillDraft parse(String words, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final text = words.trim().replaceAll('，', ',').replaceAll('。', '.')
      .replaceAll('人民币', '').replaceAll('￥', '');
    final hints = <String>[];
    final income = RegExp(r'工资|奖金|收入|收款|收到|到账|赚了|挣了').hasMatch(text);
    final expense = RegExp(r'支出|花了|花费|支付|付了|买了|购买|交了|缴').hasMatch(text);
    final type = income && !expense ? 'income' : 'expense';
    if (income && expense) hints.add('句子同时包含收支，请确认类型');
    var date = today;
    if (text.contains('前天')) {
      date = DateTime(clock.year, clock.month, clock.day - 2);
    } else if (text.contains('昨天')) {
      date = DateTime(clock.year, clock.month, clock.day - 1);
    }
    final dated = RegExp('(?:([0-9]{4})年)?([$_numbers]{1,3})月([$_numbers]{1,3})[日号]').firstMatch(text);
    if (dated != null) {
      final year = int.tryParse(dated.group(1) ?? '') ??
        (text.contains('去年') ? clock.year - 1 : text.contains('明年') ? clock.year + 1 : clock.year);
      final month = _integer(dated.group(2)!);
      final day = _integer(dated.group(3)!);
      if (month != null && day != null && year >= 1900 && year <= 2200 &&
          month >= 1 && month <= 12 && day >= 1 &&
          day <= DateTime(year, month + 1, 0).day) {
        date = DateTime(year, month, day);
      } else {
        hints.add('日期没有识别完整，请在确认页调整');
      }
    } else if (RegExp(r'上周|上个月|去年|明年|明天|后天').hasMatch(text)) {
      hints.add('请在确认页选择准确日期');
    }

    final matches = _money.allMatches(text).toList();
    final malformedAmount = RegExp(
      '[-负][$_numbers]+(?:[点.][$_numbers]+)?\\s*(?:元|块)|'
      '[$_numbers]+[点.][0-9零〇一二两三四五六七八九]{3,}|'
      '[0-9]+[点.][0-9]+[点.][0-9]+|'
      '[0-9]+,[0-9]{3}(?:[^0-9]|\$)').hasMatch(text);
    int? cents;
    if (matches.length == 1) {
      final m = matches.single;
      cents = _decimalCents(m.group(1)!);
      if (cents != null) {
        cents += (_integer(m.group(2) ?? '0') ?? 0) * 10;
        cents += _integer(m.group(3) ?? '0') ?? 0;
        // Common spoken shorthand: “七块五” means 7.50, not 7.05.
        if (m.group(2) == null && m.group(3) == null &&
            m.group(0)!.contains('块') && m.end < text.length) {
          final shorthand = RegExp(r'^([0-9零〇一二两三四五六七八九])(?:[,。.！!]|$)')
            .firstMatch(text.substring(m.end));
          if (shorthand != null) cents += (_integer(shorthand.group(1)!) ?? 0) * 10;
        }
      }
    } else if (matches.length > 1) {
      hints.add('识别到多个金额，请一次说一笔账单或手动填写总额');
    } else {
      final actionAmounts = RegExp(
        '(?:花了|花费|支出|支付了?|付了|收入|收到|到账|工资|奖金)\\s*'
        '([$_numbers]+(?:[点.][0-9零〇一二两三四五六七八九]{1,2})?)'
        '(?![${_numbers}点.,])')
        .allMatches(text).toList();
      if (actionAmounts.length == 1) cents = _decimalCents(actionAmounts.single.group(1)!);
    }
    if (malformedAmount) {
      cents = null;
      hints.add('金额格式不明确，请在确认页重新填写');
    }
    if (RegExp(r'没花|没有花|未支付|没买|没有买|不记|取消').hasMatch(text)) {
      cents = null;
      hints.add('这句话可能没有实际发生收支，请核对');
    }
    if (cents == null || cents <= 0) {
      cents = null;
      if (!hints.any((h) => h.contains('金额'))) hints.add('金额未识别，请在确认页填写');
    }
    return VoiceBillDraft(type: type, title: _title(text, type),
      amountCents: cents, date: date, hints: hints);
  }

  static String _title(String text, String type) {
    if (type == 'income') {
      for (final name in ['工资', '奖金', '房租', '利息', '兼职', '红包']) {
        if (text.contains(name)) return name;
      }
    }
    var title = text.replaceAll(RegExp(r'今天|昨天|前天|刚刚|刚才'), '')
      .replaceAll(RegExp('(?:[0-9]{4}年)?[$_numbers]{1,3}月[$_numbers]{1,3}[日号]'), '')
      .replaceFirst(RegExp(r'^\s*我(?:们)?'), '').trim();
    final purchase = RegExp(r'(?:买了?|购买了?|交了?|缴了?)([^,。.；;]+)').firstMatch(title);
    if (purchase != null) title = purchase.group(1)!;
    title = title.split(RegExp(r'[,；;。]')).first;
    title = title.replaceAll(RegExp(r'(?:一共|总共|合计)?(?:花了|花费|支付了?|付了|支出).*'), '')
      .replaceAll(_money, '').replaceAll(RegExp(r'^(?:收到|收入|到账|收款)(?:了)?'), '')
      .replaceFirst(RegExp('^\\s*[$_numbers]+(?:包|瓶|盒|杯|袋|个|份|件|张|次|碗|斤|公斤)'), '')
      .replaceAll(RegExp(r'[\s.]+$'), '').trim();
    if (title.isEmpty) title = type == 'income' ? '收入' : '支出';
    return title.length > 40 ? title.substring(0, 40) : title;
  }

  static int? _decimalCents(String value) {
    final parts = value.replaceAll('点', '.').split('.');
    final integer = _integer(parts.first);
    if (integer == null || parts.length > 2) return null;
    if (parts.length == 1) return integer * 100;
    final fraction = parts[1].split('').map((c) => _digits[c] ?? int.tryParse(c)).toList();
    if (fraction.isEmpty || fraction.length > 2 || fraction.contains(null)) return null;
    return integer * 100 + fraction[0]! * 10 + (fraction.length == 2 ? fraction[1]! : 0);
  }
  static const _digits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2,
    '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  static int? _integer(String text) {
    final numeric = int.tryParse(text);
    if (numeric != null) return numeric;
    if (!text.contains(RegExp(r'[十百千万]'))) {
      final digits = text.split('').map((c) => _digits[c]).toList();
      return digits.contains(null) ? null : int.tryParse(digits.join());
    }
    var result = 0, section = 0, digit = 0;
    for (final character in text.split('')) {
      final value = _digits[character] ?? int.tryParse(character);
      if (value != null) { digit = value; continue; }
      final unit = {'十': 10, '百': 100, '千': 1000, '万': 10000}[character];
      if (unit == null) return null;
      if (unit == 10000) {
        result += (section + digit) * unit;
        section = 0;
      } else {
        section += (digit == 0 ? 1 : digit) * unit;
      }
      digit = 0;
    }
    return result + section + digit;
  }
}
