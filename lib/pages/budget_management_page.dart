import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/budget.dart';
import '../models/category.dart';
import '../models/ledger.dart';
import '../models/expense_record.dart';
import '../models/app_settings.dart';
import '../services/monthly_budget_service.dart';

class BudgetManagementPage extends StatefulWidget {
  final int? initialLedgerId;
  final DateTime? initialMonth;
  const BudgetManagementPage({super.key, this.initialLedgerId, this.initialMonth});
  @override
  State<BudgetManagementPage> createState() => _BudgetManagementPageState();
}

class _BudgetManagementPageState extends State<BudgetManagementPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _db = DatabaseHelper();
  late DateTime _month;
  int? _userId;
  List<Budget> _budgets = [];
  List<Ledger> _ledgers = [];
  List<Category> _categories = [];
  List<ExpenseRecord> _records = [];
  bool _loading = true;
  String? _error;
  @override
  void initState() { super.initState(); _month = widget.initialMonth ?? DateTime.now(); _load(); }
  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final user = await _db.getCurrentUser();
      final ledgers = await _db.getAllLedgers(userId: user.id);
      final categories = await _db.getAllCategories(userId: user.id, type: 'expense');
      final budgets = await _db.getAllBudgets();
      final start = DateTime(_month.year, _month.month);
      final end = DateTime(_month.year, _month.month + 1, 0);
      final records = await _db.getRecordsByDateRange(start, end, userId: user.id);
      if (!mounted) return;
      setState(() {
        _userId = user.id; _ledgers = ledgers; _categories = categories; _records = records;
        _budgets = budgets.where((b) => ledgers.any((l) => l.id == b.ledgerId) && b.cycle == 'month'
          && b.startDate.year == _month.year && b.startDate.month == _month.month).toList();
        _loading = false;
      });
    } catch (_) { if (mounted) setState(() { _loading = false; _error = '预算加载失败，请重试'; }); }
  }
  String _ledgerName(int id) => _ledgers.firstWhere((l) => l.id == id).name;
  String _categoryName(int? id) => id == null ? '总预算' : _categories.where((c) => c.id == id).firstOrNull?.name ?? '已删除分类';
  double _spent(Budget budget) {
    final summary = _ledgers.any((l) => l.id == budget.ledgerId && l.isDefault == 1);
    return _records.where((r) => r.type == 'expense' && (summary || r.ledgerId == budget.ledgerId)
      && (budget.categoryId == null || r.categoryId == budget.categoryId))
      .fold<double>(0, (sum, r) => sum + r.amount);
  }
  Future<void> _edit([Budget? budget]) async {
    if (_ledgers.isEmpty || _userId == null) return;
    final form = GlobalKey<FormState>();
    final controller = TextEditingController(text: budget?.amount.toStringAsFixed(2) ?? '');
    var ledgerId = budget?.ledgerId ?? (_ledgers.any((l) => l.id == widget.initialLedgerId) ? widget.initialLedgerId! : _ledgers.first.id!);
    var categoryId = budget?.categoryId;
    var saving = false;
    String? error;
    final saved = await showDialog<bool>(context: context, barrierDismissible: false, builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, update) => PopScope(canPop: !saving, child: AlertDialog(
        title: Text('${_month.year}年${_month.month}月预算'),
        content: SizedBox(width: 360, child: AbsorbPointer(absorbing: saving, child: Form(key: form,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(initialValue: ledgerId, isExpanded: true,
              decoration: const InputDecoration(labelText: '账本'),
              items: _ledgers.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
              onChanged: budget == null ? (v) => update(() => ledgerId = v!) : null),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(initialValue: categoryId, isExpanded: true,
              decoration: const InputDecoration(labelText: '预算范围'),
              items: [const DropdownMenuItem<int>(value: null, child: Text('整个账本')),
                ..._categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))],
              onChanged: budget == null ? (v) => update(() => categoryId = v) : null),
            const SizedBox(height: 16),
            TextFormField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '预算金额', prefixText: '¥ '),
              validator: (v) { final n = double.tryParse(v?.trim() ?? '');
                return n == null || !n.isFinite || n <= 0 ? '请输入大于0的金额' : null; }),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error))),
          ]))))),
        actions: [TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: saving ? null : () async {
            if (!form.currentState!.validate()) return;
            update(() { saving = true; error = null; });
            try {
              // Editing preserves the original row ID and date range.
              if (budget != null) {
                final edited = Budget(id: budget.id, ledgerId: budget.ledgerId, categoryId: budget.categoryId,
                  amount: double.parse(controller.text.trim()), cycle: budget.cycle, startDate: budget.startDate,
                  endDate: budget.endDate, userId: budget.userId, cloudId: budget.cloudId);
                await _db.updateBudget(edited); budgetDataRevision.value++;
              } else {
                await MonthlyBudgetService(_db).save(userId: _userId!, ledgerId: ledgerId,
                  categoryId: categoryId, month: _month, amount: double.parse(controller.text.trim()));
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext, true);
            } catch (_) { if (dialogContext.mounted) update(() { saving = false; error = '保存失败，请重试'; }); }
          }, child: Text(saving ? '保存中…' : '保存'))],
      ))));
    // Wait for the dialog exit animation before releasing its controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (saved == true && mounted) await _load();
  }
  Future<void> _delete(Budget budget) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('删除预算？'), content: const Text('不会删除任何账单。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))]));
    if (confirmed != true || !mounted) return;
    try { await _db.deleteBudget(budget.id!); budgetDataRevision.value++; if (mounted) await _load(); }
    catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除失败，请重试'))); }
  }
  void _move(int direction) { _month = DateTime(_month.year, _month.month + direction); _load(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('预算管理')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [IconButton(onPressed: _loading ? null : () => _move(-1), icon: const Icon(Icons.chevron_left)),
        Expanded(child: Text('${_month.year}年${_month.month}月', textAlign: TextAlign.center)),
        IconButton(onPressed: _loading ? null : () => _move(1), icon: const Icon(Icons.chevron_right))]),
      if (_loading) const Center(child: CircularProgressIndicator())
      else if (_error != null) Column(children: [Text(_error!), TextButton(onPressed: _load, child: const Text('重试'))])
      else ...[
        if (_budgets.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('本月还没有预算'))),
        ..._budgets.map((b) {
          final spent = _spent(b);
          final exceeded = spent > b.amount;
          return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text('${_ledgerName(b.ledgerId)} · ${_categoryName(b.categoryId)}')),
                IconButton(tooltip: '编辑预算', onPressed: () => _edit(b), icon: const Icon(Icons.edit_outlined)),
                IconButton(tooltip: '删除预算', onPressed: () => _delete(b), icon: const Icon(Icons.delete_outline))]),
              Text('已支出 ¥${spent.toStringAsFixed(2)} / 预算 ¥${b.amount.toStringAsFixed(2)}'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: b.amount > 0 ? (spent / b.amount).clamp(0.0, 1.0) : 0,
                color: exceeded ? Theme.of(context).colorScheme.error : null),
              const SizedBox(height: 8),
              Text(exceeded ? '超支 ¥${(spent - b.amount).toStringAsFixed(2)}' : '剩余 ¥${(b.amount - spent).toStringAsFixed(2)}',
                style: TextStyle(color: exceeded ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant)),
            ])));
        }),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _ledgers.isEmpty ? null : () => _edit(), icon: const Icon(Icons.add), label: const Text('设置月度预算')),
        const Padding(padding: EdgeInsets.only(top: 16), child: Text('总账本预算按全部账本支出计算。分类预算与总预算分别展示，不重复相加。预算按月设置，不发送通知。')),
      ],
    ]),
  );
}
