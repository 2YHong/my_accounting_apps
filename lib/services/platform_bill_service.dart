import 'dart:convert';

import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/import_review.dart';
import '../models/refund_net.dart';
import 'bill_csv_service.dart';
import 'bill_file_reader.dart';
import 'bill_category_classifier.dart';
import 'bill_investment_filter.dart';
import 'refund_plan_service.dart';

class PlatformBillService {
  final DatabaseHelper db;
  PlatformBillService(this.db);

  static const _completed = {
    '支付成功', '交易成功', '转账成功', '收款成功', '已收钱', '已到账',
    '已转账', '对方已收钱', '已存入零钱', '退款成功', '交易完成', '已完成',
  };

  static bool _hasValue(String value) =>
      !['', '/', '-', '--', '—', '不适用', 'N/A', 'n/a', 'null', '无', '暂无'].contains(value.trim());

  static double? _amount(String value) => double.tryParse(
      value.replaceAll(RegExp(r'[¥￥,，\s]'), ''));

  static bool _validAmount(double? value) => value != null && value.isFinite &&
      value > 0 && (value * 100 - (value * 100).round()).abs() <= .000001;

  static bool _trustworthyOrder(String order) => _hasValue(order) &&
      !order.contains('[数字精度') && !order.contains('[公式单元格') &&
      !RegExp(r'^\d+(?:\.\d+)?[eE][+-]?\d+$').hasMatch(order);

  static DateTime? _date(String value) {
    final normalized = value.trim().replaceAll('/', '-');
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})'
        r'(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(\.\d+)?)?'
        r'(Z|[+-]\d{2}:?\d{2})?)?$').firstMatch(normalized);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final calendar = DateTime(year, month, day);
    if (year < 1900 || year > 2200 || calendar.year != year || calendar.month != month || calendar.day != day ||
        int.parse(match[4] ?? '0') > 23 || int.parse(match[5] ?? '0') > 59 ||
        int.parse(match[6] ?? '0') > 59) return null;
    final iso = '${match[1]}-${match[2]!.padLeft(2, '0')}-${match[3]!.padLeft(2, '0')}'
        '${match[4] == null ? '' : 'T${match[4]!.padLeft(2, '0')}:${match[5]}:${match[6] ?? '00'}${match[7] ?? ''}${match[8] ?? ''}'}';
    return DateTime.tryParse(iso);
  }

  // Only explicit separator/footer lines are omitted. A damaged transaction
  // with a missing date or direction must remain available for review.
  static bool _footer(List<String> row, {required String date,
      required String direction, required String order,
      required List<String> amounts}) {
    if (_hasValue(direction) || _hasValue(order) ||
        amounts.any(_hasValue) ||
        RegExp(r'^\d{4}[-/]').hasMatch(date)) return false;
    final text = row.map(BillFileReader.clean).where((v) => v.isNotEmpty).join(' ');
    return RegExp(r'^[-=─━_\s]{3,}$').hasMatch(text) ||
        RegExp(r'^(?:温馨提示|账单说明|文件说明|导出时间|起始时间|终止时间|'
            r'收入合计|支出合计|交易记录共|共\s*\d+\s*笔|'
            r'总计\s*[:：]|合计\s*[:：])').hasMatch(text);
  }

  static Map<String, String> _original(List<String> headers, List<String> row) {
    final original = <String, String>{};
    for (var i = 0; i < headers.length || i < row.length; i++) {
      final name = i < headers.length && headers[i].isNotEmpty
          ? headers[i] : '未命名列${i + 1}';
      var key = name;
      var suffix = 2;
      while (original.containsKey(key)) { key = '$name（${suffix++}）'; }
      original[key] = i < row.length ? row[i] : '';
    }
    return original;
  }

  Future<BillImportPreview> preview(BillTable table, {required int ledgerId,
    int? accountId, int? expenseCategoryId, int? incomeCategoryId,
    bool autoClassify = true,
    String fileName = ''}) async {
    final user = await db.getCurrentUser();
    final ledgers = await db.getAllLedgers(userId: user.id);
    final categories = await BillCategoryClassifier.ensureFallbacks(db, user.id!);
    final accounts = await db.getAllAssetAccounts(userId: user.id);
    if (!ledgers.any((l) => l.id == ledgerId)) throw const FormatException('请选择有效账本');
    if (((!autoClassify || expenseCategoryId != null) &&
        !categories.any((c) => c.id == expenseCategoryId && c.type == 'expense')) ||
        ((!autoClassify || incomeCategoryId != null) &&
        !categories.any((c) => c.id == incomeCategoryId && c.type == 'income'))) {
      throw const FormatException('请选择有效的收支分类');
    }
    if (accountId != null && !accounts.any((a) => a.id == accountId)) {
      throw const FormatException('请选择有效账户');
    }
    final database = await db.database;
    final reviewRows = await database.query('import_reviews', columns: ['row_key', 'status', 'payload'],
        where: 'user_id = ?', whereArgs: [user.id]);
    final seenReviews = reviewRows.map((r) => r['row_key'] as String).toSet();
    final ledgerIds = ledgers.map((ledger) => ledger.id).toSet();
    final recordRows = await database.query('expense_records',
        where: 'ledger_id IN (SELECT id FROM ledgers WHERE user_id = ?)', whereArgs: [user.id]);
    final sourceRows = await database.query('refund_sources', where: 'user_id = ?', whereArgs: [user.id]);
    final eventRows = await database.query('refund_events', where: 'user_id = ?', whereArgs: [user.id]);
    final seen = recordRows.map(ExpenseRecord.fromMap)
        .where((record) => ledgerIds.contains(record.ledgerId))
        .map((record) => BillCsvService.fingerprintForUser(record, user.id)).toSet();
    seen.addAll(BillCsvService.removedRecordFingerprints(reviewRows, user.id));
    final records = <ExpenseRecord>[];
    final reviews = <ImportReviewDraft>[];
    final evidence = <RefundEvidence>[];
    final errors = <String>[];
    final skipped = <String>[];
    var duplicates = 0;
    final headers = table.headers;
    final duplicateHeaders = headers.toSet().length != headers.length;
    final originalHeaders = table.originalHeaders;
    final successfulRefundColumn = originalHeaders.indexWhere((h) =>
        ['成功退款(元)', '成功退款', '累计成功退款(元)', '累计成功退款',
          '已成功退款金额(元)', '累计已退款金额(元)'].contains(BillFileReader.header(h)));
    final cumulativeTemplate = successfulRefundColumn >= 0;
    String readRow(List<String> row, String key) {
      final direct = headers.indexOf(key);
      if (direct >= 0 && direct < row.length && BillFileReader.clean(row[direct]).isNotEmpty) {
        return BillFileReader.clean(row[direct]);
      }
      for (var index = 0; index < headers.length && index < row.length; index++) {
        if (BillFileReader.canonicalHeader(headers[index]) == key && BillFileReader.clean(row[index]).isNotEmpty) {
          return BillFileReader.clean(row[index]);
        }
      }
      return '';
    }
    // Include malformed/pending rows in identity conflict detection: a valid
    // first row must not be deducted when another row contradicts its ID.
    final refundSignatures = <String, Set<String>>{};
    for (final row in table.rows) {
      final id = readRow(row, '退款号');
      if (!_trustworthyOrder(id)) continue;
      final originalOrder = readRow(row, '原交易号');
      final rawRefund = readRow(row, '退款金额');
      final rawAmount = _hasValue(rawRefund) ? rawRefund : readRow(row, '金额');
      final cents = refundMoneyCents(rawAmount);
      refundSignatures.putIfAbsent(id, () => {}).add(jsonEncode([originalOrder, cents ?? rawAmount]));
    }
    final conflictingRefundIds = refundSignatures.entries.where((e) => e.value.length > 1)
        .map((e) => e.key).toSet();

    for (var i = 0; i < table.rows.length; i++) {
      final row = table.rows[i];
      if (row.every((v) => v.trim().isEmpty)) continue;
      final number = i + table.headerRow + 1;
      String value(String key) => readRow(row, key);

      final direction = value('收/支').replaceAll(RegExp(r'\s'), '');
      final rawDate = value('交易时间');
      final order = value('交易号');
      if (_footer(row, date: rawDate, direction: direction, order: order,
          amounts: [value('金额'), value('收入金额'), value('支出金额'), value('退款金额')])) {
        continue;
      }
      final status = value('交易状态');
      final transactionClass = value('交易分类');
      if (BillInvestmentFilter.isInvestment(category: transactionClass,
          title: value('商品说明'), description: value('备注'), counterparty: value('交易对方'))) {
        skipped.add('第$number行：明确的投资相关支出或收入，不计入日常收支');
        continue;
      }
      final rawRefund = value('退款金额');
      final originalOrder = value('原交易号');
      final refundId = value('退款号');
      final isIndependent = _hasValue(originalOrder) || _hasValue(refundId);
      final independentSucceeded = ['退款成功', '退回成功', '已退款', '成功'].contains(
          value('退款状态').isEmpty ? status : value('退款状态'));
      final explicitFullRefund = ['已全额退款', '全额退款成功'].contains(status);
      final refund = _amount(rawRefund);
      final mentionsRefund = RegExp(r'退款|退回|退还').hasMatch('$status $transactionClass');
      final hasRefund = mentionsRefund || isIndependent || (refund != null && refund.isFinite && refund > 0);
      final invalidRefund = _hasValue(rawRefund) &&
          (refund == null || !refund.isFinite || refund < 0 ||
              (refund * 100 - (refund * 100).round()).abs() > .000001);

      // Refunds take priority over no-income/no-expense and closed statuses.
      if (!hasRefund && !invalidRefund && RegExp(r'关闭|失败|取消|未支付|未付款|已撤回|已撤销').hasMatch(status)) {
        skipped.add('第$number行：$status，不计入收支');
        continue;
      }
      final ignored = ['/', '不计收支', '不计收入支出', '不计收/支'].contains(direction);
      if (ignored && !hasRefund && !invalidRefund) {
        skipped.add('第$number行：不计收支');
        continue;
      }

      final reasons = <String>[];
      if (duplicateHeaders) reasons.add('表头存在重复列，请核对原始字段');
      if (row.skip(headers.length).any((v) => v.trim().isNotEmpty)) {
        reasons.add('记录列数超出表头，原始整行已保留');
      }
      final eligibleRefund = (cumulativeTemplate || explicitFullRefund ||
          (isIndependent && independentSucceeded)) &&
          (value('币种').isEmpty || ['人民币', 'CNY', 'RMB', '人民币元'].contains(value('币种').toUpperCase()));
      if (hasRefund && !eligibleRefund) reasons.add(refund != null && refund > 0
          ? '成功退款金额为¥${refund.toStringAsFixed(2)}，请核对原交易与实际收支'
          : '涉及退款，请核对原交易与实际收支');
      if (invalidRefund) reasons.add('退款金额格式无法识别，请核对原始金额');

      final rawIncome = value('收入金额');
      final rawExpense = value('支出金额');
      final income = _amount(rawIncome);
      final expense = _amount(rawExpense);
      final incomePositive = income != null && income.isFinite && income > 0;
      final expensePositive = expense != null && expense.isFinite && expense > 0;
      String? type = direction == '支出' ? 'expense' : direction == '收入' ? 'income' : null;
      if (type == null && incomePositive != expensePositive) {
        type = incomePositive ? 'income' : 'expense';
      }
      if (type == null && ignored && hasRefund) type = 'income';
      if (eligibleRefund && (isIndependent || explicitFullRefund || cumulativeTemplate) &&
          (direction == '支出' || ignored || isIndependent)) type = 'expense';
      if (direction.isNotEmpty && direction != '支出' && direction != '收入' && !ignored) {
        reasons.add('无法识别收支类型：$direction');
      } else if (type == null) {
        reasons.add('收支类型缺失或无法确定');
      }
      if (incomePositive && expensePositive) reasons.add('收入和支出金额同时存在，请确认收支方向');
      if ((_hasValue(rawIncome) && (income == null || !income.isFinite || income < 0)) ||
          (_hasValue(rawExpense) && (expense == null || !expense.isFinite || expense < 0))) {
        reasons.add('收入或支出金额列格式无效');
      }
      var rawAmount = value('金额');
      if (!_hasValue(rawAmount)) rawAmount = type == 'income' ? rawIncome : rawExpense;
      if (!_hasValue(rawAmount) && hasRefund && type == 'income') rawAmount = rawRefund;
      if (isIndependent && _hasValue(rawRefund)) rawAmount = rawRefund;
      final amount = _amount(rawAmount);
      if (!_validAmount(amount)) reasons.add('金额无效，请核对原始金额（最多两位小数）');
      final splitAmount = type == 'income' ? income : expense;
      if (_validAmount(amount) && _validAmount(splitAmount) &&
          ((amount! - splitAmount!).abs() > .000001)) {
        reasons.add('总金额与收支金额列不一致');
      }
      if ((type == 'expense' && incomePositive) || (type == 'income' && expensePositive)) {
        reasons.add('收支方向与分列金额不一致');
      }
      if (!_completed.contains(status) && !explicitFullRefund &&
          !(isIndependent && independentSucceeded) &&
          !(cumulativeTemplate && (refundMoneyCents(rawRefund) ?? 0) > 0 && status.isNotEmpty &&
            !RegExp(r'失败|处理中|申请|待退款|退款中|未支付|未付款').hasMatch(status))) {
        reasons.add('交易状态需要核对：${status.isEmpty ? '空白' : status}');
      }
      final date = _date(isIndependent && value('退款时间').isNotEmpty ? value('退款时间') : rawDate);
      if (date == null) reasons.add('交易时间缺失或格式无法识别');
      final trustworthyOrder = _trustworthyOrder(order);
      if (_hasValue(order) && !trustworthyOrder) {
        reasons.add('交易号可能被表格转换并丢失精度，请核对原始文件');
      }

      final counterparty = value('交易对方');
      final counterpartyAccount = value('对方账号');
      final product = value('商品说明');
      final method = value('支付方式');
      final note = value('备注');
      final expenseCategory = BillCategoryClassifier.choose(categories: categories,
          type: 'expense', originalCategory: transactionClass, title: product,
          merchant: counterparty, description: note,
          overrideCategoryId: autoClassify ? null : expenseCategoryId)!;
      final incomeCategory = BillCategoryClassifier.choose(categories: categories,
          type: 'income', originalCategory: transactionClass, title: product,
          merchant: counterparty, description: note,
          overrideCategoryId: autoClassify ? null : incomeCategoryId)!;
      final candidate = type != null && _validAmount(amount) && date != null
          ? ExpenseRecord(ledgerId: ledgerId, userId: user.id,
              categoryId: type == 'expense' ? expenseCategory.id! : incomeCategory.id!,
              assetAccountId: accountId, type: type, amount: amount!, date: date,
              title: _hasValue(product) ? product : _hasValue(counterparty) ? counterparty
                : _hasValue(transactionClass) ? transactionClass : '${table.source}交易',
              note: [table.source, if (_hasValue(counterparty)) '对方：$counterparty',
                if (_hasValue(counterpartyAccount)) '对方账号：$counterpartyAccount',
                if (_hasValue(method)) '方式：$method', if (_hasValue(note)) note,
                if (_hasValue(order)) '交易号：$order',
                if (hasRefund && status.isNotEmpty) '状态：$status',
                if (hasRefund && _hasValue(rawRefund)) '原始退款金额：$rawRefund'].join(' · '),
              importKey: trustworthyOrder ? '${table.source}:$order' : null)
          : null;
      if (isIndependent) {
        if (conflictingRefundIds.contains(refundId)) reasons.add('同一退款单号对应不同原订单或金额，全部留待核对');
        if (cumulativeTemplate && _hasValue(rawRefund)) reasons.add('独立退款与累计成功退款列同时出现，金额含义需要核对');
        if (!_trustworthyOrder(originalOrder) || !_trustworthyOrder(refundId)) {
          reasons.add('独立退款缺少完整的原交易单号或退款单号');
        }
        if (!independentSucceeded) reasons.add('退款尚未明确成功，请稍后核对');
      }
      if (hasRefund && !isIndependent && !trustworthyOrder) reasons.add('退款订单缺少有效原交易单号');
      if (hasRefund && eligibleRefund && type != 'expense') reasons.add('退款对应原交易不是明确支出');
      if (hasRefund && eligibleRefund && !isIndependent && cumulativeTemplate &&
          refundMoneyCents(rawRefund) == null) reasons.add('累计成功退款金额缺失或格式无效');
      if (candidate != null && reasons.isEmpty && type == 'expense' &&
          (trustworthyOrder || (isIndependent && _trustworthyOrder(originalOrder)))) {
        final gross = refundMoneyCents(rawAmount);
        if (gross == null) {
          reasons.add('原付款或退款金额无法按精确分值读取');
        } else {
          final cumulative = isIndependent ? null : explicitFullRefund ? gross
              : cumulativeTemplate ? refundMoneyCents(rawRefund) : null;
          evidence.add(RefundEvidence(importKey: '${table.source}:${isIndependent ? originalOrder : order}',
            source: table.source, original: _original(originalHeaders, row), rowNumber: number,
            payment: isIndependent ? null : candidate, grossCents: isIndependent ? null : gross,
            cumulativeCents: cumulative, refundId: isIndependent ? refundId : null,
            eventCents: isIndependent ? refundMoneyCents(rawAmount) : null,
            snapshotAt: table.exportedAt, refundedAt: isIndependent ? date : null));
          continue;
        }
      }
      if (reasons.isNotEmpty || candidate == null) {
        final original = _original(originalHeaders, row);
        final rowKey = trustworthyOrder
            ? jsonEncode([table.source, order, transactionClass, status, direction,
                _validAmount(amount) ? amount!.toStringAsFixed(2) : rawAmount,
                _validAmount(refund) ? refund!.toStringAsFixed(2) : rawRefund, rawDate])
            : jsonEncode([table.source, original]);
        if (!seenReviews.add(rowKey)) { duplicates++; continue; }
        final reason = reasons.isEmpty ? '无法生成账单，请核对原始记录' : reasons.toSet().join('；');
        reviews.add(ImportReviewDraft(userId: user.id!, source: table.source,
          rowKey: rowKey, reason: reason, fileName: fileName, original: original,
          candidate: candidate, ledgerId: ledgerId, accountId: accountId,
          expenseCategoryId: expenseCategory.id!, incomeCategoryId: incomeCategory.id!));
        errors.add('第$number行：$reason');
        continue;
      }
      if (!seen.add(BillCsvService.fingerprint(candidate))) { duplicates++; continue; }
      records.add(candidate);
    }
    final removedKeys = BillCsvService.removedRecordFingerprints(reviewRows, user.id)
        .map((key) => (jsonDecode(key) as List)[1] as String).toSet();
    final planned = RefundPlanService.build(userId: user.id!, evidence: evidence, recordRows: recordRows,
      sourceRows: sourceRows, eventRows: eventRows, removedImportKeys: removedKeys);
    duplicates += planned.duplicates;
    for (final failure in planned.failures) {
      final item = failure.evidence;
      final rowKey = jsonEncode([table.source, 'refund_net', item.original]);
      if (!seenReviews.add(rowKey)) { duplicates++; continue; }
      reviews.add(ImportReviewDraft(userId: user.id!, source: table.source,
        rowKey: rowKey, reason: failure.reason, fileName: fileName, original: item.original,
        candidate: item.payment, ledgerId: ledgerId, accountId: accountId,
        expenseCategoryId: expenseCategoryId ?? categories.firstWhere((c) => c.type == 'expense' && c.name == '其他支出').id!,
        incomeCategoryId: incomeCategoryId ?? categories.firstWhere((c) => c.type == 'income' && c.name == '其他收入').id!));
      errors.add('第${item.rowNumber}行：${failure.reason}');
    }
    records.addAll(planned.plans.where((p) => p.isNew).map((p) => p.record));
    return BillImportPreview(records, errors, duplicates, skipped: skipped, reviewItems: reviews,
      refundPlans: planned.plans);
  }
}

