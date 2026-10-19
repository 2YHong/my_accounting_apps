import 'package:flutter/material.dart';
import '../models/ledger.dart';
import '../models/category.dart';
import '../models/asset_account.dart';
import '../services/bill_category_classifier.dart';
import '../services/bill_file_reader.dart';

class PlatformImportOptions {
  final int ledgerId;
  final int? accountId;
  final int? expenseCategoryId;
  final int? incomeCategoryId;
  final bool autoClassify;
  const PlatformImportOptions(this.ledgerId, this.accountId,
      this.expenseCategoryId, this.incomeCategoryId, {this.autoClassify = true});
}

class PlatformImportOptionsDialog extends StatefulWidget {
  final String source;
  final List<Ledger> ledgers;
  final List<Category> categories;
  final List<AssetAccount> accounts;
  const PlatformImportOptionsDialog({super.key, required this.source, required this.ledgers,
    required this.categories, required this.accounts});
  @override
  State<PlatformImportOptionsDialog> createState() => _PlatformImportOptionsDialogState();
}

class _PlatformImportOptionsDialogState extends State<PlatformImportOptionsDialog> {
  final _form = GlobalKey<FormState>();
  int? _ledgerId;
  int? _accountId;
  int? _expenseId;
  int? _incomeId;
  bool _autoClassify = true;
  @override
  void initState() {
    super.initState();
    _ledgerId = widget.ledgers.firstOrNull?.id;
    for (final type in ['expense', 'income']) {
      final fallback = BillCategoryClassifier.choose(categories: widget.categories, type: type);
      if (type == 'expense') { _expenseId = fallback?.id; } else { _incomeId = fallback?.id; }
    }
  }
  Widget _category(String type, String label, int? id, ValueChanged<int?> change) => DropdownButtonFormField<int>(
    initialValue: id, isExpanded: true, decoration: InputDecoration(labelText: label),
    items: widget.categories.where((c) => c.type == type).map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
    validator: (v) => v == null ? '请先创建对应分类' : null, onChanged: change);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('导入${widget.source}账单'),
    content: SizedBox(width: 380, child: Form(key: _form, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<int>(initialValue: _ledgerId, isExpanded: true,
          decoration: const InputDecoration(labelText: '导入到账本'),
          items: widget.ledgers.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
          validator: (v) => v == null ? '请先创建账本' : null, onChanged: (v) => setState(() => _ledgerId = v)),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(initialValue: _accountId, isExpanded: true,
          decoration: const InputDecoration(labelText: '关联账户'),
          items: [const DropdownMenuItem<int>(value: null, child: Text('不关联账户')),
            ...widget.accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))],
          onChanged: (v) => setState(() => _accountId = v)),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(contentPadding: EdgeInsets.zero,
          title: Text(widget.source == BillFileReader.namedSource ? '保留表格分类' : '自动分类'),
          subtitle: Text(widget.source == BillFileReader.namedSource
            ? '保留原分类名称，缺少的分类在确认导入后创建'
            : '根据原分类和交易内容识别；无法识别时放入其他支出或其他收入'),
          value: _autoClassify, onChanged: (v) => setState(() => _autoClassify = v)),
        if (!_autoClassify) ...[
          const SizedBox(height: 12),
          _category('expense', '统一支出分类', _expenseId, (v) => setState(() => _expenseId = v)),
          const SizedBox(height: 16),
          _category('income', '统一收入分类', _incomeId, (v) => setState(() => _incomeId = v)),
        ],
        const SizedBox(height: 12),
        Text(widget.source == BillFileReader.namedSource
          ? '描述会作为标题，空描述用原分类作标题；标签和原账户名称保存在备注。默认不关联账户，不改变现有余额；主动选择关联账户后会按收支更新余额。'
          : '导入后可逐笔调整分类。关联账户会按收支更新余额；补导历史账单且不希望影响余额时，请选择“不关联账户”。',
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ])))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () { if (_form.currentState!.validate()) Navigator.pop(context,
        PlatformImportOptions(_ledgerId!, _accountId,
          _autoClassify ? null : _expenseId, _autoClassify ? null : _incomeId,
          autoClassify: _autoClassify)); }, child: const Text('查看预览'))],
  );
}
