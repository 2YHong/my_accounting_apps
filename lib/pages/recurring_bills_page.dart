import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/asset_account.dart';
import '../models/category.dart';
import '../models/expense_record.dart';
import '../models/ledger.dart';
import '../models/recurring_bill.dart';
import '../services/recurring_bill_service.dart';
import '../services/recurring_notifications.dart';

class RecurringBillsPage extends StatefulWidget {
  final Widget? reminderControl;
  const RecurringBillsPage({super.key, this.reminderControl});
  @override
  State<RecurringBillsPage> createState() => _RecurringBillsPageState();
}

class _RecurringBillsPageState extends State<RecurringBillsPage> with WidgetsBindingObserver {
  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _service = RecurringBillService(DatabaseHelper());
  List<RecurringBill> _rules = [];
  List<RecurringOccurrence> _pending = [];
  int _pendingCount = 0;
  int _loadGeneration = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    recurringDataRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _releaseSyncEdit();
    WidgetsBinding.instance.removeObserver(this);
    recurringDataRevision.removeListener(_load);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final pending = await _service.getPendingOccurrences();
      final count = await _service.getPendingCount();
      final rules = await _service.getAll();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _pending = pending; _pendingCount = count; _rules = rules;
        _loading = false; _error = null; _loadingMore = false;
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) setState(() {
        _loading = false; _error = _message(error); _loadingMore = false;
      });
    }
  }

  String _message(Object error) => error is FormatException
    ? error.message.toString() : '读取或保存失败，请重试';

  Future<void> _more() async {
    if (_loadingMore || _pending.length >= _pendingCount) return;
    final generation = _loadGeneration;
    setState(() => _loadingMore = true);
    try {
      final items = await _service.getPendingOccurrences(offset: _pending.length);
      if (mounted && generation == _loadGeneration) {
        setState(() { _pending.addAll(items); _loadingMore = false; });
      }
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadingMore = false);
        _showError(error);
      }
    }
  }

  void _showError(Object error) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_message(error))));
  }

  Future<void> _edit({RecurringBill? rule, RecurringOccurrence? occurrence, String? template}) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) =>
      _RecurringEditorPage(rule: rule, occurrence: occurrence, template: template)));
    if (mounted) await _load();
  }

  Future<void> _new() async {
    final template = await showModalBottomSheet<String>(context: context,
      showDragHandle: true, builder: (context) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text('新增固定收支', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final name in ['房租', '房贷', '车贷', '手机月租', '视频订阅', '其他订阅', '工资', '自定义'])
                ActionChip(label: Text(name), onPressed: () => Navigator.pop(context, name)),
            ]),
          ]))));
    if (template != null && mounted) await _edit(template: template);
  }

  Future<void> _toggle(RecurringBill rule, bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await _service.setEnabled(rule.id!, enabled); }
    catch (error) { _showError(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _delete(RecurringBill rule) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('删除固定收支？'),
      content: Text('删除“${rule.title}”及其未确认提醒。已经记入账单的记录会保留。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))]));
    if (confirmed != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try { await _service.delete(rule.id!); }
    catch (error) { _showError(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(appBar: AppBar(title: const Text('固定收支')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _busy ? null : _new,
        icon: const Icon(Icons.add), label: const Text('新增计划')),
      body: _loading ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(onRefresh: _load, child: ListView(
          physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          children: [
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(Icons.event_repeat_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10), Expanded(child: Text('每月到期，确认后记账', style: theme.textTheme.titleMedium))]),
                const SizedBox(height: 10),
                const Text('金额变化时，可先修改本期金额再确认。每期只记一次；29至31日遇到短月，会安排在月末。'),
                const SizedBox(height: 8),
                const Text('确认后再次导入同笔微信或支付宝付款，请核对重复记录；软件暂不会自动合并。'),
                if (widget.reminderControl != null) ...[const SizedBox(height: 12), widget.reminderControl!],
              ]))),
            if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: TextButton(onPressed: _load, child: Text('$_error，点击重试'))),
            const SizedBox(height: 16),
            Text('待确认${_pendingCount == 0 ? '' : ' · $_pendingCount期'}', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_pending.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('目前没有到期待确认的收支')),
            for (final item in _pending) Card(child: ListTile(
              leading: Icon(item.snapshot.type == 'income' ? Icons.south_west : Icons.north_east,
                color: theme.colorScheme.primary),
              title: Text(item.snapshot.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.dueDate.year}年${item.dueDate.month}月${item.dueDate.day}日到期 · ${item.snapshot.type == 'income' ? '收入' : '支出'} ¥${item.snapshot.amountText}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _edit(occurrence: item))),
            if (_pending.length < _pendingCount) TextButton(onPressed: _loadingMore ? null : _more,
              child: Text(_loadingMore ? '读取中…' : '显示更多待确认期')),
            const SizedBox(height: 24),
            Text('我的计划', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_rules.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('添加房租、月租或订阅费，到期后在这里确认')),
            for (final rule in _rules) Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(children: [Expanded(child: InkWell(onTap: _busy ? null : () => _edit(rule: rule),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(rule.title, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text('${rule.type == 'income' ? '收入' : '支出'} ¥${rule.amountText} · 每月${rule.dayOfMonth}日'),
                    if (!rule.enabled) Text('已暂停', style: TextStyle(color: theme.colorScheme.outline)),
                  ])))),
                Switch(value: rule.enabled, onChanged: _busy ? null : (value) => _toggle(rule, value)),
                PopupMenuButton<String>(enabled: !_busy, onSelected: (value) {
                  if (value == 'edit') _edit(rule: rule);
                  if (value == 'delete') _delete(rule);
                }, itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑计划')),
                  PopupMenuItem(value: 'delete', child: Text('删除计划')),
                ]),
              ]))),
            if (_rules.any((rule) => !rule.enabled)) const Padding(padding: EdgeInsets.only(top: 12),
              child: Text('暂停期间不产生新提醒；重新开启后从当天继续，之前到期的待确认项可继续核对或跳过。')),
          ])));
  }
}

class _RecurringEditorPage extends StatefulWidget {
  final RecurringBill? rule;
  final RecurringOccurrence? occurrence;
  final String? template;
  const _RecurringEditorPage({this.rule, this.occurrence, this.template});
  @override
  State<_RecurringEditorPage> createState() => _RecurringEditorPageState();
}

class _RecurringEditorPageState extends State<_RecurringEditorPage> {
  final _db = DatabaseHelper();
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  List<Ledger> _ledgers = [];
  List<Category> _categories = [];
  List<AssetAccount> _accounts = [];
  int? _ledgerId;
  int? _categoryId;
  int? _accountId;
  late String _type;
  late DateTime _date;
  late int _day;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  bool get _confirming => widget.occurrence != null;
  RecurringBill? get _source => widget.occurrence?.snapshot ?? widget.rule;

  @override
  void initState() {
    super.initState();
    final source = _source;
    _title = TextEditingController(text: source?.title ?? (widget.template == '自定义' ? '' : widget.template ?? ''));
    _amount = TextEditingController(text: source?.amountText ?? '');
    _note = TextEditingController(text: source?.note ?? '');
    _type = source?.type ?? (widget.template == '工资' ? 'income' : 'expense');
    _date = widget.occurrence?.dueDate ?? source?.startDate ?? RecurringBill.dateOnly(DateTime.now());
    _day = source?.dayOfMonth ?? DateTime.now().day;
    _loadOptions();
  }

  @override
  void dispose() { _title.dispose(); _amount.dispose(); _note.dispose(); super.dispose(); }

  Future<void> _loadOptions() async {
    try {
      final user = await _db.getCurrentUser();
      final ledgers = await _db.getAllLedgers(userId: user.id);
      final categories = await _db.getAllCategories(userId: user.id);
      final accounts = await _db.getAllAssetAccounts(userId: user.id);
      if (!mounted) return;
      final source = _source;
      setState(() {
        _ledgers = ledgers; _categories = categories; _accounts = accounts;
        _ledgerId = source == null ? ledgers.firstOrNull?.id
          : ledgers.any((item) => item.id == source.ledgerId) ? source.ledgerId : null;
        _accountId = accounts.any((item) => item.id == source?.assetAccountId) ? source?.assetAccountId : null;
        _categoryId = source == null ? _preferredCategory()
          : categories.any((item) => item.id == source.categoryId && item.type == _type) ? source.categoryId : null;
        if (source != null && (_ledgerId == null || _categoryId == null ||
          (source.assetAccountId != null && _accountId == null))) {
          _error = '原账本、分类或账户已删除，请核对下方选项后重新选择';
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = '记账选项读取失败，请返回后重试'; });
    }
  }

  int? _preferredCategory() {
    final template = widget.template ?? _title.text;
    final wanted = _type == 'income' ? (template.contains('工资') ? '工资' : '其他收入')
      : ['房租', '房贷'].contains(template) ? '住房'
      : template == '车贷' ? '交通'
      : template.contains('订阅') ? '娱乐' : '其他支出';
    final options = _categories.where((item) => item.type == _type).toList();
    return options.where((item) => item.name == wanted).firstOrNull?.id ??
      options.where((item) => item.name == (_type == 'income' ? '其他收入' : '其他支出')).firstOrNull?.id ?? options.firstOrNull?.id;
  }

  Future<void> _pickDate() async {
    final first = _confirming || widget.rule != null ? DateTime(1900) : RecurringBill.dateOnly(DateTime.now());
    final initial = _date.isBefore(first) ? first : _date;
    final date = await showDatePicker(context: context, initialDate: initial,
      firstDate: first, lastDate: DateTime(2200, 12, 31));
    if (date != null && mounted) setState(() => _date = date);
  }

  Future<void> _save() async {
    if (_saving || _loading || !_form.currentState!.validate()) return;
    final cents = RecurringBill.parseAmountCents(_amount.text)!;
    setState(() { _saving = true; _error = null; });
    try {
      final service = RecurringBillService(_db);
      if (_confirming) {
        await service.confirm(widget.occurrence!, ExpenseRecord(
          ledgerId: _ledgerId!, type: _type, amount: cents / 100,
          categoryId: _categoryId!, assetAccountId: _accountId, date: _date,
          title: _title.text.trim(), note: _note.text.trim()));
      } else {
        await service.save(RecurringBill(id: widget.rule?.id, title: _title.text.trim(),
          type: _type, amountCents: cents, ledgerId: _ledgerId!, categoryId: _categoryId!,
          assetAccountId: _accountId, dayOfMonth: _day, startDate: _date,
          activeFrom: widget.rule?.activeFrom ?? RecurringBill.dateOnly(DateTime.now()),
          enabled: widget.rule?.enabled ?? true, note: _note.text.trim()));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() {
        _saving = false; _error = error is FormatException ? error.message.toString() : '保存失败，请重试';
      });
    }
  }

  Future<void> _skip() async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('本期不记账？'), content: const Text('本期标记为已跳过，下个月仍会正常提醒。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('跳过本期'))]));
    if (yes != true || !mounted || _saving) return;
    setState(() => _saving = true);
    try {
      await RecurringBillService(_db).skip(widget.occurrence!);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = error is FormatException ? error.message.toString() : '保存失败，请重试'; });
    }
  }

  Future<void> _linkExisting() async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      final service = RecurringBillService(_db);
      final records = await service.getExistingCandidates(widget.occurrence!);
      if (!mounted) return;
      if (records.isEmpty) {
        setState(() { _saving = false; _error = '到期月份前后没有可关联的账单。若已经记账，也可以选择“本期不记账”。'; });
        return;
      }
      final selected = await showModalBottomSheet<ExpenseRecord>(context: context,
        showDragHandle: true, isScrollControlled: true,
        builder: (context) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .7,
          child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('选择已经记过的账单', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('请核对名称、金额和日期。这里只关联已有账单，不新增支出或收入。'),
              const SizedBox(height: 12),
              Expanded(child: ListView.builder(itemCount: records.length, itemBuilder: (context, index) {
                final record = records[index];
                final category = _categories.where((item) => item.id == record.categoryId).firstOrNull;
                final ledger = _ledgers.where((item) => item.id == record.ledgerId).firstOrNull;
                return ListTile(title: Text(record.displayTitle(category?.name), maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                  subtitle: Text('${record.date.year}年${record.date.month}月${record.date.day}日 · ${ledger?.name ?? ''}'),
                  trailing: Text('¥${record.amount.toStringAsFixed(2)}'),
                  onTap: () => Navigator.pop(context, record));
              })),
            ])))));
      if (!mounted) return;
      if (selected == null) { setState(() => _saving = false); return; }
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('关联这笔已有账单？'),
        content: Text('“${selected.title ?? '已有账单'}” ¥${selected.amount.toStringAsFixed(2)}\n${selected.date.year}年${selected.date.month}月${selected.date.day}日\n关联后，本期标记为已完成。已有账单的内容会保留。'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认关联'))]));
      if (!mounted) return;
      if (confirmed != true) { setState(() => _saving = false); return; }
      await service.linkExisting(widget.occurrence!, selected.id!);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() {
        _saving = false; _error = error is FormatException ? error.message.toString() : '读取或关联失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(canPop: !_saving, child: Scaffold(
    appBar: AppBar(title: Text(_confirming ? '确认本期收支' : widget.rule == null ? '新增固定收支' : '编辑固定收支')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : AbsorbPointer(absorbing: _saving,
      child: Form(key: _form, child: ListView(padding: const EdgeInsets.all(20), children: [
        if (_confirming) Card(child: Padding(padding: const EdgeInsets.all(14),
          child: Text('${widget.occurrence!.period.replaceFirst('-', '年')}月待确认。核对金额和日期后再记账，本次修改只影响本期。已经手动或导入记过这笔时，请关联已有账单或跳过本期。'))),
        if (!_confirming && widget.rule != null) const Padding(padding: EdgeInsets.only(bottom: 16),
          child: Text('计划修改用于之后的期次。已到期的项目可在确认时单独修改。')),
        SegmentedButton<String>(segments: const [ButtonSegment(value: 'expense', label: Text('支出')),
          ButtonSegment(value: 'income', label: Text('收入'))], selected: {_type},
          onSelectionChanged: (values) => setState(() { _type = values.first; _categoryId = _preferredCategory(); })),
        const SizedBox(height: 20),
        TextFormField(controller: _title, maxLength: 100, decoration: const InputDecoration(labelText: '名称'),
          validator: (value) => value == null || value.trim().isEmpty ? '请输入名称' : null),
        const SizedBox(height: 12),
        TextFormField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: _confirming ? '本期实际金额' : '每月金额', prefixText: '¥ '),
          validator: (value) => RecurringBill.parseAmountCents(value ?? '') == null ? '请输入大于0的金额，最多两位小数' : null),
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(initialValue: _ledgerId, isExpanded: true,
          decoration: const InputDecoration(labelText: '账本'),
          items: _ledgers.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
          validator: (value) => value == null ? '请选择账本' : null,
          onChanged: (value) => setState(() => _ledgerId = value)),
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(initialValue: _accountId, isExpanded: true,
          decoration: const InputDecoration(labelText: '账户'), items: [
            const DropdownMenuItem<int>(value: null, child: Text('不关联账户')),
            ..._accounts.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))),
          ], onChanged: (value) => setState(() => _accountId = value)),
        const SizedBox(height: 20),
        OutlinedButton.icon(onPressed: _pickDate, icon: const Icon(Icons.calendar_today_outlined),
          label: Text('${_confirming ? '交易日期' : '开始日期'}：${_date.year}年${_date.month}月${_date.day}日')),
        if (!_confirming) ...[const SizedBox(height: 20),
          DropdownButtonFormField<int>(initialValue: _day, isExpanded: true,
            decoration: const InputDecoration(labelText: '每月提醒日期'),
            items: List.generate(31, (index) => DropdownMenuItem(value: index + 1,
              child: Text(index >= 28 ? '${index + 1}日（短月按月末）' : '${index + 1}日'))),
            onChanged: (value) => setState(() => _day = value ?? _day)),
          const SizedBox(height: 8), const Text('从开始日期之后的第一个到期日提醒。不会补记创建之前的月份。'),
        ],
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(key: ValueKey('recurring-category-$_type-$_categoryId'),
          initialValue: _categoryId, isExpanded: true, decoration: const InputDecoration(labelText: '分类'),
          items: _categories.where((item) => item.type == _type)
            .map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
          validator: (value) => value == null ? '请选择分类' : null,
          onChanged: (value) => setState(() => _categoryId = value)),
        const SizedBox(height: 20),
        TextFormField(controller: _note, maxLines: 2, decoration: const InputDecoration(labelText: '备注（选填）')),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 24),
        FilledButton(onPressed: _saving || _ledgerId == null || _categoryId == null ? null : _save,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(_saving ? '保存中…' : _confirming ? '确认并记入账单' : '保存计划'))),
        if (_confirming) ...[const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _saving ? null : _linkExisting,
            icon: const Icon(Icons.link), label: const Text('已记过这笔，关联已有账单')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _saving ? null : _skip, child: const Text('本期不记账')),
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('稍后确认')),
        ],
      ]))),
  ));
}
