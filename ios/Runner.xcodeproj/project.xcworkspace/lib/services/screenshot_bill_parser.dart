class ScreenshotBillDraft {
  final String type, title;
  final int? amountCents;
  final DateTime date;
  final List<String> hints;
  const ScreenshotBillDraft(
    this.type,
    this.title,
    this.amountCents,
    this.date,
    this.hints,
  );
}

/// Conservative, single-detail screenshot parser. IDs, balances and times must
/// not become money. Ambiguous candidates stay blank for the existing editor.
class ScreenshotBillParser {
  static ScreenshotBillDraft parse(String source, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final lines = source
        .replaceAll('￥', '¥')
        .replaceAll('−', '-')
        .split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final text = lines.join('\n');
    final hints = <String>['截图识别结果请核对后保存；账户不会自动选择。'];
    final income = RegExp(
      r'收入|收款成功|已收款|已收钱|转账收入|到账|received|income|credited',
      caseSensitive: false,
    ).hasMatch(text);
    final expense = RegExp(
      r'支出|支付成功|付款成功|已支付|已付款|payment successful|paid|debit',
      caseSensitive: false,
    ).hasMatch(text);
    final positive = lines.any(
      (l) => RegExp(
        r'^\+\s*(?:¥|CNY|RMB)?\s*\d',
        caseSensitive: false,
      ).hasMatch(l),
    );
    final type = income && !expense || positive && !expense
        ? 'income'
        : 'expense';
    if (income && expense) hints.add('同时出现收支字样，请确认收支类型。');
    final candidates = <int, Set<int>>{};
    final money = RegExp(
      r'(?:[¥$]\s*|(?:CNY|RMB)\s*)?([+-]?\s*\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)\s*(?:元|CNY|RMB)?',
      caseSensitive: false,
    );
    bool excluded(String l) => RegExp(
      r'余额|优惠|折扣|原价|订单号|交易号|单号|流水|手机号|balance|discount|order\s*(?:id|no)|transaction\s*(?:id|no)',
      caseSensitive: false,
    ).hasMatch(l);
    bool amountLabel(String l) => RegExp(
      r'实付|实际支付|付款金额|支付金额|收款金额|转账金额|交易金额|总金额|合计|金额|amount|total|paid',
      caseSensitive: false,
    ).hasMatch(l);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (excluded(line)) continue;
      final matches = money.allMatches(line).toList();
      if (matches.length != 1) continue;
      final m = matches.single;
      final raw = m.group(1)!.replaceAll(RegExp(r'[\s,+-]'), '');
      final pieces = raw.split('.');
      final integer = int.tryParse(pieces.first);
      if (integer == null) continue;
      final cents =
          integer * 100 +
          int.parse((pieces.length == 1 ? '' : pieces[1]).padRight(2, '0'));
      if (cents <= 0 || cents > 99999999999) continue;
      final currency = RegExp(
        r'[¥$]|元|CNY|RMB',
        caseSensitive: false,
      ).hasMatch(line);
      final signed = RegExp(r'^[+-]\s*\d+(?:\.\d{1,2})?$').hasMatch(line);
      final labeled =
          amountLabel(line) ||
          i > 0 && amountLabel(lines[i - 1]) && !excluded(lines[i - 1]);
      final bare = line == m.group(0)!.trim() && raw.contains('.');
      if (!currency && !signed && !labeled && !bare) continue;
      if (RegExp(r'^\d{4}[-/年]').hasMatch(line) ||
          RegExp(r'\d{1,2}:\d{2}').hasMatch(line))
        continue;
      final score = labeled
          ? 3
          : currency || signed
          ? 2
          : 1;
      candidates.putIfAbsent(score, () => <int>{}).add(cents);
    }
    int? amount;
    if (candidates.isNotEmpty) {
      final scores = candidates.keys.toList()..sort();
      final values = candidates[scores.last]!;
      if (values.length == 1) amount = values.single;
    }
    if (amount == null) hints.add('金额不明确，请手动填写；请优先使用单笔账单详情截图。');
    var date = DateTime(clock.year, clock.month, clock.day);
    final dates = RegExp(
      r'(20\d{2})[-/年.](\d{1,2})[-/月.](\d{1,2})',
    ).allMatches(text);
    final validDates = <String, DateTime>{};
    for (final m in dates) {
      final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
      final v = DateTime(y, mo, d);
      if (v.year == y && v.month == mo && v.day == d) {
        validDates['$y-$mo-$d'] = v;
      }
    }
    if (validDates.length == 1) {
      date = validDates.values.single;
    } else {
      hints.add('日期未明确识别，暂填今天，请确认。');
    }
    var title = '';
    final label = RegExp(
      r'^(?:商家(?:名称)?|商品(?:说明)?|收款方|付款方|交易对方|merchant|description|payee)\s*[:：]?\s*(.*)$',
      caseSensitive: false,
    );
    for (var i = 0; i < lines.length; i++) {
      final m = label.firstMatch(lines[i]);
      if (m == null) continue;
      final value = m[1]!.trim().isNotEmpty
          ? m[1]!.trim()
          : i + 1 < lines.length
          ? lines[i + 1]
          : '';
      if (value.isNotEmpty &&
          !excluded(value) &&
          !RegExp(r'^[¥$\d+-]').hasMatch(value)) {
        title = value;
        break;
      }
    }
    if (title.isEmpty) {
      title =
          lines
              .where(
                (l) =>
                    !RegExp(
                      r'支付|付款|账单|详情|交易|成功|时间|方式|服务|帮助|备注|订单|编号|收款|金额|微信|支付宝|payment|transaction|details|amount|time',
                      caseSensitive: false,
                    ).hasMatch(l) &&
                    RegExp(r'[A-Za-z\u4e00-\u9fff]').hasMatch(l) &&
                    !RegExp(r'\d{5}|:|¥|\$').hasMatch(l),
              )
              .firstOrNull ??
          '';
    }
    if (title.length > 60) title = title.substring(0, 60);
    return ScreenshotBillDraft(type, title, amount, date, hints);
  }
}
