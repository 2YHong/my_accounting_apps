import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:gbk_codec/gbk_codec.dart';

class BillTable {
  final String sheet;
  final String source;
  final List<String> headers;
  final List<List<String>> rows;
  final int headerRow;
  final List<String> originalHeaders;
  final DateTime? exportedAt;

  BillTable(this.sheet, this.source, this.headers, this.rows, this.headerRow,
    {List<String>? originalHeaders, this.exportedAt})
    : originalHeaders = originalHeaders ?? headers;

  bool get external => source != '本软件';
}

class _DecodedBillText {
  final String text;
  final String encoding;

  const _DecodedBillText(this.text, this.encoding);
}

class BillFileReader {
  static const namedSource = '通用表格';
  static const namedHeaders = ['类型', '金额', '日期', '分类', '标签', '描述', '账户'];
  static String clean(String value) => value
      .replaceAll(RegExp('[\uFEFF\u200B\u200C\u200D\u2060]'), '')
      .trim();

  /// Formatting-only normalization, retained for existing callers.
  static String header(String value) => clean(value)
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('／', '/')
      .replaceAll(RegExp(r'id$', caseSensitive: false), 'ID');

  /// Stable names shared by platform parsing and the review queue.
  /// Amount columns stay separate so split income/expense exports retain data.
  static String canonicalHeader(String value) {
    final normalized = header(value);
    return switch (normalized) {
      '交易创建时间' || '创建时间' || '交易日期' || '交易日期时间' ||
      '交易日期(时间)' || '交易时间(北京时间)' || '交易发生时间' ||
      '记账时间' => '交易时间',
      '收支' || '收入/支出' || '收入支出' || '收支类型' ||
      '收支方向' => '收/支',
      '金额(元)' || '交易金额' || '交易金额(元)' ||
      '金额(人民币)' || '金额(人民币元)' => '金额',
      '收入(元)' || '收入金额(元)' || '收入金额' => '收入金额',
      '支出(元)' || '支出金额(元)' || '支出金额' => '支出金额',
      '成功退款(元)' || '成功退款' || '退款金额(元)' || '累计成功退款' ||
      '累计成功退款(元)' => '退款金额',
      '原交易单号' || '原交易订单号' || '原微信支付订单号' ||
      '原支付宝交易号' || '原订单号' => '原交易号',
      '退款单号' || '退款订单号' || '退款交易号' => '退款号',
      '退款成功时间' || '退款到账时间' => '退款时间',
      '退款状态说明' => '退款状态',
      '交易币种' || '货币' => '币种',
      '交易单号' || '交易订单号' || '支付宝交易号' || '支付宝订单号' ||
      '微信交易单号' || '微信支付订单号' => '交易号',
      '对方名称' || '交易对方名称' || '对方户名' => '交易对方',
      '商品' || '商品名称' || '交易说明' => '商品说明',
      '收/付款方式' || '收付款方式' || '付款方式' ||
      '支付渠道' => '支付方式',
      '当前状态' || '交易状态说明' => '交易状态',
      '交易类型' => '交易分类',
      '交易备注' => '备注',
      _ => normalized,
    };
  }

  static String? _source(List<String> originalHeaders, {String hint = ''}) {
    final headers = originalHeaders.map(canonicalHeader).toSet();
    if (headers.contains('账本ID') &&
        headers.contains('分类ID') &&
        headers.contains('金额')) {
      return '本软件';
    }
    if (originalHeaders.map(header).toSet().containsAll(namedHeaders)) {
      return namedSource;
    }
    final hasSplitAmount = headers.contains('收入金额') ||
        headers.contains('支出金额');
    final refundOnly = headers.contains('原交易号') && headers.contains('退款号') &&
      headers.contains('退款时间') && headers.contains('退款状态') &&
      (headers.contains('退款金额') || headers.contains('金额'));
    if (!refundOnly && (!headers.contains('交易时间') ||
        !(headers.contains('金额') || hasSplitAmount) ||
        !(headers.contains('收/支') || hasSplitAmount))) {
      return null;
    }
    // Detect the source before merging order-number and status aliases.
    // Official Alipay exports can provide only 对方账号, without a person's
    // name or product column. Source identification therefore uses the date,
    // direction, amount and explicit platform order columns/description.
    // Keep 对方账号 separate: exports containing both name and account need both.
    final raw = originalHeaders.map(header).toSet();
    final loweredHint = hint.toLowerCase();
    final alipayHint = loweredHint.contains('支付宝') ||
        loweredHint.contains('alipay');
    final wechatHint = loweredHint.contains('微信') ||
        loweredHint.contains('wechat');
    if (raw.contains('支付宝交易号') ||
        raw.contains('支付宝订单号') ||
        raw.contains('交易订单号')) {
      return '支付宝';
    }
    if (raw.contains('微信交易单号') ||
        raw.contains('微信支付订单号') ||
        raw.contains('交易单号') ||
        raw.contains('商户单号')) {
      return '微信';
    }
    if (alipayHint && !wechatHint) return '支付宝';
    if (wechatHint && !alipayHint) return '微信';
    if (raw.contains('交易号') || raw.contains('商家订单号')) {
      return '支付宝';
    }
    return null;
  }

  static List<String> _canonicalHeaders(List<String> original) {
    final canonical = original.map(canonicalHeader).toList();
    final result = List<String>.of(canonical);
    // An old export can contain several meaningful time/name columns. Keep
    // secondary aliases under their original names rather than lose a column.
    for (final key in canonical.toSet()) {
      final indices = <int>[
        for (var i = 0; i < canonical.length; i++)
          if (canonical[i] == key) i,
      ];
      if (indices.length < 2) continue;
      final preferred = indices.firstWhere(
        (i) => header(original[i]) == key,
        orElse: () => indices.first,
      );
      for (final index in indices) {
        if (index != preferred) result[index] = header(original[index]);
      }
    }
    return result;
  }

  static BillTable? _table(String name, List<List<String>> rows,
      {String sourceHint = ''}) {
    for (var i = 0; i < rows.length; i++) {
      final original = rows[i].map(header).toList();
      while (original.isNotEmpty && original.last.isEmpty) {
        original.removeLast();
      }
      final fields = original.map(canonicalHeader).toSet();
      if (!fields.contains('金额') && !fields.contains('收入金额') &&
          !fields.contains('支出金额') && !fields.contains('退款金额')) {
        continue;
      }
      final prefix = rows.take(i).map((row) => row.join(' ')).join('\n');
      final source = _source(original, hint: '$sourceHint $name $prefix');
      if (source != null) {
        return BillTable(name, source, _canonicalHeaders(original),
            rows.skip(i + 1).toList(), i + 1,
            originalHeaders: original, exportedAt: _exportedAt(prefix));
      }
    }
    return null;
  }

  // A transaction date or a file-modified date cannot date a cumulative refund
  // snapshot. Only an explicit statement export timestamp supplies that proof.
  static DateTime? _exportedAt(String prefix) {
    final matches = RegExp(r'(?:账单导出时间|导出时间|文件生成时间)[\s:：,，;；]+'
      r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T]'
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?'
      r'(Z|[+-]\d{2}:?\d{2})?').allMatches(prefix);
    final dates = <DateTime>{};
    for (final match in matches) {
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final hour = int.parse(match[4]!);
      final minute = int.parse(match[5]!);
      final second = int.parse(match[6] ?? '0');
      final date = DateTime(year, month, day, hour, minute, second);
      if (year >= 1900 && year <= 2200 && date.year == year && date.month == month &&
        date.day == day && hour <= 23 && minute <= 59 && second <= 59) {
        final zone = match[7];
        final parsed = zone == null ? date : DateTime.tryParse(
          '${match[1]}-${match[2]!.padLeft(2, '0')}-${match[3]!.padLeft(2, '0')}'
          'T${match[4]!.padLeft(2, '0')}:${match[5]}:${match[6] ?? '00'}$zone');
        if (parsed != null) dates.add(parsed);
      }
    }
    return dates.length == 1 ? dates.single : null;
  }

  static String _cell(CellValue? value) => switch (value) {
        null => '',
        TextCellValue() => value.value.toString(),
        IntCellValue() => value.value.abs() >= 1000000000000000
            ? '[数字精度丢失风险]'
            : value.value.toString(),
        DoubleCellValue() => value.value.abs() >= 1000000000000000
            ? '[数字精度丢失风险]'
            : value.value.toString(),
        DateCellValue() => value.asDateTimeLocal().toIso8601String(),
        DateTimeCellValue() => value.asDateTimeLocal().toIso8601String(),
        FormulaCellValue() => '[公式单元格，请粘贴为值]',
        _ => value.toString(),
      };

  static String _utf16(List<int> bytes,
      {required bool littleEndian, required int start}) {
    if ((bytes.length - start).isOdd) {
      throw const FormatException('UTF-16文件不完整，请重新下载或另存为UTF-8 CSV');
    }
    final units = <int>[];
    for (var i = start; i < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= units.length ||
            units[i + 1] < 0xDC00 ||
            units[i + 1] > 0xDFFF) {
          throw const FormatException('UTF-16文字编码损坏，请重新下载原始账单');
        }
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        throw const FormatException('UTF-16文字编码损坏，请重新下载原始账单');
      }
    }
    return String.fromCharCodes(units);
  }

  static _DecodedBillText _decode(List<int> bytes) {
    if (bytes.length >= 4 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE &&
                bytes[2] == 0 && bytes[3] == 0) ||
            (bytes[0] == 0 && bytes[1] == 0 &&
                bytes[2] == 0xFE && bytes[3] == 0xFF))) {
      throw const FormatException('暂不支持UTF-32，请另存为UTF-8 CSV后导入');
    }
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _DecodedBillText(
            _utf16(bytes, littleEndian: true, start: 2), 'UTF-16 LE');
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _DecodedBillText(
            _utf16(bytes, littleEndian: false, start: 2), 'UTF-16 BE');
      }
    }
    // Some spreadsheet editors omit the UTF-16 BOM. Repeated ASCII + NUL
    // pairs identify the byte order without treating arbitrary UTF-8 as UTF-16.
    var littleAscii = 0;
    var bigAscii = 0;
    final limit = bytes.length < 512 ? bytes.length : 512;
    for (var i = 0; i + 1 < limit; i += 2) {
      if (bytes[i + 1] == 0 && bytes[i] >= 9 && bytes[i] <= 126) {
        littleAscii++;
      }
      if (bytes[i] == 0 && bytes[i + 1] >= 9 && bytes[i + 1] <= 126) {
        bigAscii++;
      }
    }
    if (littleAscii >= 4 && littleAscii > bigAscii * 3) {
      return _DecodedBillText(
          _utf16(bytes, littleEndian: true, start: 0), 'UTF-16 LE（无BOM）');
    }
    if (bigAscii >= 4 && bigAscii > littleAscii * 3) {
      return _DecodedBillText(
          _utf16(bytes, littleEndian: false, start: 0), 'UTF-16 BE（无BOM）');
    }
    try {
      return _DecodedBillText(utf8.decode(bytes), 'UTF-8');
    } on FormatException {
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        throw const FormatException('UTF-8文件不完整，请重新下载原始账单');
      }
      for (var i = 0; i + 3 < bytes.length; i++) {
        if (bytes[i] >= 0x81 && bytes[i] <= 0xFE &&
            bytes[i + 1] >= 0x30 && bytes[i + 1] <= 0x39 &&
            bytes[i + 2] >= 0x81 && bytes[i + 2] <= 0xFE &&
            bytes[i + 3] >= 0x30 && bytes[i + 3] <= 0x39) {
          throw const FormatException('该文件使用GB18030扩展编码，请另存为UTF-8 CSV后导入');
        }
      }
      return _DecodedBillText(gbk_bytes.decode(bytes), 'GBK');
    }
  }

  static BillTable _csv(String name, _DecodedBillText decoded) {
    final text = decoded.text.replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text.split('\n');
    const delimiters = {',': '逗号', '\t': '制表符', ';': '分号'};
    final foundFields = <String>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.contains('金额') && !line.contains('成功退款') &&
          !line.contains('收入') && !line.contains('支出')) {
        continue;
      }
      for (final entry in delimiters.entries) {
        final converter = CsvToListConverter(
          fieldDelimiter: entry.key,
          eol: '\n',
          shouldParseNumbers: false,
          allowInvalid: false,
        );
        List<List<dynamic>> candidate;
        try {
          candidate = converter.convert(line);
        } on FormatException {
          continue;
        }
        if (candidate.isEmpty) continue;
        final original = candidate.first.map((v) => header(v.toString())).toList();
        final canonical = original.map(canonicalHeader).toSet();
        // Diagnostics report field names only, never transaction body content.
        const expected = {'交易时间', '交易对方', '收/支', '金额',
          '收入金额', '支出金额', '交易号', '账本ID', '分类ID'};
        if (original.length > 1) foundFields.addAll(canonical.intersection(expected));
        final source = _source(original,
            hint: '$name ${lines.take(i).join('\n')}');
        if (source == null) continue;
        List<List<String>> rows;
        try {
          rows = converter.convert(lines.skip(i).join('\n'))
              .map((row) => row.map((value) => value.toString()).toList()).toList();
        } on FormatException {
          throw FormatException('已在第${i + 1}行识别到$source表头'
              '（${decoded.encoding}，${entry.value}分隔）。'
              'CSV格式不完整，可能有未闭合引号；请重新导入平台原始文件，或另存为UTF-8 CSV');
        }
        final table = _table('CSV', rows, sourceHint: '$source $name');
        if (table != null) {
          return BillTable(table.sheet, table.source, table.headers,
              table.rows, i + table.headerRow, originalHeaders: table.originalHeaders,
              exportedAt: _exportedAt(lines.take(i).join('\n')));
        }
      }
    }
    final fields = foundFields.isEmpty ? '未识别到必要字段' :
        '已识别字段：${foundFields.join('、')}';
    throw FormatException('未找到账单表头（${decoded.encoding}；已尝试逗号、制表符和分号）。'
        '$fields。请导入支付宝或微信下载后解压出的原始明细文件，'
        '表头需包含交易时间、收/支及金额（或收入/支出金额列），并可识别支付宝或微信来源；'
        '也支持包含类型、金额、日期、分类、标签、描述和账户的通用表格');
  }

  static List<BillTable> read(String name, List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('文件为空');
    final lowerName = name.trim().toLowerCase();
    final isZip = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    if (lowerName.endsWith('.zip') || (isZip && !lowerName.endsWith('.xlsx'))) {
      throw const FormatException('选择的是压缩包或Excel文件，请先解压账单压缩包，并选择其中的.csv或.xlsx文件');
    }
    if (lowerName.endsWith('.xls') ||
        (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF &&
            bytes[2] == 0x11 && bytes[3] == 0xE0)) {
      throw const FormatException('暂不支持旧版.xls，请在Excel中另存为.xlsx或CSV后导入');
    }
    if (!lowerName.endsWith('.xlsx')) return [_csv(name, _decode(bytes))];

    final tables = <BillTable>[];
    try {
      final workbook = Excel.decodeBytes(bytes);
      for (final entry in workbook.tables.entries) {
        final rows = entry.value.rows
            .map((row) => row.map((cell) => _cell(cell?.value)).toList()).toList();
        final table = _table(entry.key, rows, sourceHint: name);
        if (table != null) tables.add(table);
      }
    } catch (_) {
      throw const FormatException('无法读取Excel，请选择未加密的.xlsx文件（不是改扩展名），并将公式粘贴为值');
    }
    if (tables.isEmpty) {
      throw const FormatException('Excel中未找到账单表头。支持本软件、支付宝、微信及通用表格账单，'
          '表头需包含交易时间、收/支及金额（或收入/支出金额列），并可识别支付宝或微信来源');
    }
    return tables;
  }
}
