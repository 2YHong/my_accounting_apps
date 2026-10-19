import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/import_review.dart';
import '../models/expense_record.dart';
import '../models/ledger.dart';
import '../models/category.dart';
import '../models/asset_account.dart';
import '../services/import_review_service.dart';
import '../services/bill_category_classifier.dart';

class ImportReviewPage extends StatefulWidget {
  const ImportReviewPage({super.key});
  @override
  State<ImportReviewPage> createState() => _ImportReviewPageState();
}

class _ImportReviewPageState extends State<ImportReviewPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _db = DatabaseHelper();
  List<ImportReviewItem> _items = [];
  bool _loading = true;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final items = await ImportReviewService(_db).pending();
      if (mounted) setState(() { _items = items; _loading = false; });
    } catch (_) { if (mounted) setState(() { _error = '待核对列表读取失败'; _loading = false; }); }
  }
  Future<void> _open(ImportReviewItem item) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => _ReviewRecordPage(item: item)));
    if (changed == true && mounted) await _load();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('待核对账单${_items.isEmpty ? '' : ' · ${_items.length}条'}')),
    body: _loading ? const Center(child: CircularProgressIndicator())
      : _error != null ? Center(child: TextButton(onPressed: _load, child: Text('$_error，重试')))
      : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(), children: [
          const Text('这些原始记录已保存在本机，暂未计入收支。你可以稍后回来逐项核对。'),
          const SizedBox(height: 12),
          if (_items.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('全部核对完成'))),
          ..._items.map((item) {
            final r = item.candidate;
            final original = item.original;
            final title = r?.title ?? original['商品'] ?? original['商品说明'] ?? original['交易对方'] ?? item.source;
            return Card(child: ListTile(
              leading: Icon(Icons.fact_check_outlined, color: Theme.of(context).colorScheme.primary),
              title: Text(title.isEmpty ? '${item.source}账单' : title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.source} · ${r == null ? original['交易时间'] ?? '' : r.date.toIso8601String().substring(0, 10)}\n${item.reason}'),
              isThreeLine: true, trailing: const Icon(Icons.chevron_right), onTap: () => _open(item)));
          }),
        ])),
  );
}

class _ReviewRecordPage extends StatefulWidget {
  final ImportReviewItem item;
  const _ReviewRecordPage({required this.item});
  @override
  State<_ReviewRecordPage> createState() => _ReviewRecordPageState();
}

class _ReviewRecordPageState extends State<_ReviewRecordPage> {
  final _db = DatabaseHelper();
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _title;
  late final TextEditingController _note;
  String _type = 'expense';
  DateTime? _date;
  int? _ledgerId;
  int? _accountId;
  int? _categoryId;
  List<Ledger> _ledgers = [];
  List<Category> _categories = [];
  List<AssetAccount> _accounts = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  ExpenseRecord? _existing;
  @override
  void initState() {
    super.initState();
    final r = widget.item.candidate;
    final original = widget.item.original;
    _type = r?.type ?? (original['收/支'] == '收入' ? 'income' : 'expense');
    _date = r?.date;
    if (_date != null && (_date!.year < 1900 || _date!.year > 2200)) _date = null;
    _amount = TextEditingController(text: RegExp(r'退款|退回|退还').hasMatch(widget.item.reason) ? '' : r?.amount.toStringAsFixed(2) ?? '');
    _title = TextEditingController(text: r?.title ?? original['商品'] ?? original['商品说明'] ?? original['交易对方'] ?? '');
    _note = TextEditingController(text: r?.note ?? '${widget.item.source} · 经核对');
    _load();
  }
  @override
  void dispose() { _amount.dispose(); _title.dispose(); _note.dispose(); super.dispose(); }
  Future<void> _load() async {
    try {
      final user = await _db.getCurrentUser();
      final ledgers = await _db.getAllLedgers(userId: user.id);
      final categories = await BillCategoryClassifier.ensureFallbacks(_db, user.id!);
      final accounts = await _db.getAllAssetAccounts(userId: user.id);
      final existing = await ImportReviewService(_db).matchingRecord(widget.item);
      if (!mounted) return;
      setState(() {
        _ledgers = ledgers; _categories = categories; _accounts = accounts; _existing = existing;
        if (existing != null) {
          _type = existing.type;
          _date = existing.date.year >= 1900 && existing.date.year <= 2200 ? existing.date : null;
          _title.text = existing.title ?? _title.text;
          _note.text = existing.note ?? _note.text;
          _amount.clear();
        }
        final requestedLedger = existing?.ledgerId ?? (widget.item.payload['ledger_id'] as int?);
        _ledgerId = ledgers.any((l) => l.id == requestedLedger) ? requestedLedger : ledgers.firstOrNull?.id;
        final requestedAccount = existing != null ? existing.assetAccountId : widget.item.payload['account_id'] as int?;
        _accountId = accounts.any((a) => a.id == requestedAccount) ? requestedAccount : null;
        _selectCategory();
        if (existing != null && categories.any((c) => c.id == existing.categoryId && c.type == _type)) _categoryId = existing.categoryId;
        _loading = false;
      });
    } catch (e) { if (mounted) setState(() { _loading = false; _error = e is FormatException ? e.message.toString() : '记账选项读取失败，请重新打开'; }); }
  }
  void _selectCategory() {
    final preferred = widget.item.payload[_type == 'expense' ? 'expense_category_id' : 'income_category_id'] as int?;
    final original = widget.item.original;
    _categoryId = BillCategoryClassifier.choose(categories: _categories, type: _type,
      preservedCategoryId: preferred,
      originalCategory: original['交易分类'] ?? original['交易类型'] ?? '',
      title: original['商品说明'] ?? original['商品'] ?? _title.text,
      merchant: original['交易对方'] ?? '',
      description: original['备注'] ?? '')?.id;
  }
  Future<void> _pickDate() async {
    final date = await showDatePicker(context: context, initialDate: _date ?? DateTime.now(), firstDate: DateTime(1900), lastDate: DateTime(2200, 12, 31));
    if (date != null && mounted) setState(() => _date = date);
  }
  Future<void> _confirm() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (_date == null) { setState(() => _error = '请选择实际交易日期'); return; }
    setState(() { _saving = true; _error = null; });
    final importKey = ImportReviewService.importKeyFor(widget.item);
    final record = ExpenseRecord(ledgerId: _ledgerId!, categoryId: _categoryId!, assetAccountId: _accountId,
      type: _type, amount: double.parse(_amount.text.trim()), date: _date!,
      title: _title.text.trim(), note: _note.text.trim(), importKey: importKey);
    try {
      await ImportReviewService(_db).confirm(widget.item.id, record, existingRecordId: _existing?.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) { if (mounted) setState(() { _saving = false; _error = e is FormatException ? e.message.toString() : '保存失败，请重试'; }); }
  }
  Future<void> _ignore({bool removeExisting = false}) async {
    if (_saving) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(removeExisting ? '确认全额退款并撤销原账单？' : '确认不记入收支？'),
      content: Text(removeExisting
        ? '将撤销已记账的“${_existing?.title ?? ''}” ¥${_existing?.amount.toStringAsFixed(2)}，并将此项标记为已核对。原账单内容会保存在核对信息中。'
        : '此项不计入收支，已有账单保持原金额。原始核对信息会保留。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(removeExisting ? '确认撤销原账单' : '确认不计收支'))]));
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try { await ImportReviewService(_db).ignore(widget.item.id, removeRecordId: removeExisting ? _existing?.id : null); if (mounted) Navigator.pop(context, true); }
    catch (_) { if (mounted) setState(() { _saving = false; _error = '保存失败，请重试'; }); }
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_saving, child: Scaffold(
    appBar: AppBar(title: const Text('逐项核对')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : AbsorbPointer(absorbing: _saving,
      child: Form(key: _form, child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.item.reason, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
          ...widget.item.original.entries.where((e) => e.value.isNotEmpty).map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 6), child: SelectableText('${e.key}：${e.value}'))),
        ]))),
        const SizedBox(height: 16),
        const Text('打开微信或支付宝核对后，填写实际金额。部分退款可记录净支出；不要再把同一退款重复记为收入。'),
        if (_existing != null) Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(
          '已找到同一交易的账单：${_existing!.title ?? ''} · ¥${_existing!.amount.toStringAsFixed(2)}。下方确认会更新这笔账单。全额退款请选择“撤销原账单”。'))),
        const SizedBox(height: 16),
        SegmentedButton<String>(segments: const [ButtonSegment(value: 'expense', label: Text('实际支出')),
          ButtonSegment(value: 'income', label: Text('实际收入'))], selected: {_type},
          onSelectionChanged: (v) => setState(() { _type = v.first; _selectCategory(); })),
        const SizedBox(height: 16),
        TextFormField(controller: _title, decoration: const InputDecoration(labelText: '名称')),
        const SizedBox(height: 16),
        TextFormField(controller: _amount, decoration: const InputDecoration(labelText: '实际金额', prefixText: '¥ '),
          keyboardType: const TextInputType.numberWithOptions(decimal: true), validator: (v) {
            final amount = double.tryParse(v?.trim() ?? '');
            return amount == null || !amount.isFinite || amount <= 0 || (amount * 100 - (amount * 100).round()).abs() > .000001 ? '请输入大于0的实际金额，最多两位小数' : null;
          }),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(initialValue: _ledgerId, isExpanded: true,
          decoration: const InputDecoration(labelText: '账本'),
          items: _ledgers.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
          validator: (v) => v == null ? '请选择账本' : null, onChanged: (v) => setState(() => _ledgerId = v)),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(initialValue: _accountId, isExpanded: true,
          decoration: const InputDecoration(labelText: '账户'),
          items: [const DropdownMenuItem<int>(value: null, child: Text('不关联账户')),
            ..._accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))], onChanged: (v) => setState(() => _accountId = v)),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(key: ValueKey('review-category-$_type-$_categoryId'), initialValue: _categoryId,
          isExpanded: true, decoration: const InputDecoration(labelText: '分类'),
          items: _categories.where((c) => c.type == _type).map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
          validator: (v) => v == null ? '请选择分类' : null, onChanged: (v) => setState(() => _categoryId = v)),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: _pickDate, icon: const Icon(Icons.calendar_today_outlined),
          label: Text(_date == null ? '选择实际交易日期' : '${_date!.year}年${_date!.month}月${_date!.day}日')),
        const SizedBox(height: 16),
        TextFormField(controller: _note, maxLines: 3, decoration: const InputDecoration(labelText: '核对备注')),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 20),
        FilledButton(onPressed: _saving || _loading || _ledgerId == null || _categoryId == null ? null : _confirm,
          child: Padding(padding: const EdgeInsets.all(14), child: Text(_saving ? '保存中…' : _existing == null ? '确认实际金额并记账' : '确认并更新已有账单'))),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _saving ? null : () => _ignore(), child: const Text('此项不计收支 / 不重复记账')),
        if (_existing != null) TextButton(onPressed: _saving ? null : () => _ignore(removeExisting: true),
          child: const Text('已全额退款，撤销原账单')),
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('稍后核对')),
      ]))),
  ));
}
