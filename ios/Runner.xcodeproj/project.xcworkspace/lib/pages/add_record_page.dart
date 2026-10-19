import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/category.dart';
import '../models/asset_account.dart';
import '../models/ledger.dart';
import '../components/category_style.dart';
import 'record_category_dialog.dart';
import 'edit_account_page.dart';
import '../services/asset_notifications.dart';

class AddRecordPage extends StatefulWidget {
  final Function()? onRecordAdded;
  final ExpenseRecord? record;
  final ExpenseRecord? initialRecord;
  final List<String> initialHints;
  final int? defaultLedgerId;
  const AddRecordPage({
    super.key,
    this.onRecordAdded,
    this.record,
    this.initialRecord,
    this.initialHints = const [],
    this.defaultLedgerId,
  }) : assert(record == null || initialRecord == null);
  @override
  State<AddRecordPage> createState() => _AddRecordPageState();
}

class _AddRecordPageState extends State<AddRecordPage> {
  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _form = GlobalKey<FormState>();
  final _db = DatabaseHelper();
  late final TextEditingController _amount;
  late final TextEditingController _title;
  late final TextEditingController _note;
  List<Category> _categories = [];
  List<AssetAccount> _accounts = [];
  List<Ledger> _ledgers = [];
  int? _categoryId;
  int? _accountId;
  int? _ledgerId;
  int? _userId;
  String _type = 'expense';
  DateTime _date = DateTime.now();
  bool _loading = true;
  bool _saving = false;
  bool _creatingAccount = false;
  int _accountsRequest = 0;
  String? _error;
  List<Category> get _available =>
      _categories.where((c) => c.type == _type).toList();

  @override
  void initState() {
    super.initState();
    final record = widget.record ?? widget.initialRecord;
    _amount = TextEditingController(
      text:
          record != null &&
              (record.amount > 0 || record.refundGrossCents != null)
          ? record.amount.toStringAsFixed(2)
          : '',
    );
    _title = TextEditingController(text: record?.title ?? '');
    _note = TextEditingController(text: record?.note ?? '');
    _type = record?.type ?? 'expense';
    _categoryId = record?.categoryId;
    _accountId = record?.assetAccountId;
    _ledgerId = record?.ledgerId ?? widget.defaultLedgerId;
    _date = record?.date ?? DateTime.now();
    assetAccountsRevision.addListener(_onAccountsChanged);
    _loadOptions();
  }

  @override
  void dispose() {
    _releaseSyncEdit();
    assetAccountsRevision.removeListener(_onAccountsChanged);
    _amount.dispose();
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final user = await _db.getCurrentUser();
      final categories = await _db.getAllCategories(userId: user.id);
      final accounts = await _db.getAllAssetAccounts(userId: user.id);
      final ledgers = await _db.getAllLedgers(userId: user.id);
      if (!mounted) return;
      setState(() {
        _userId = user.id;
        _categories = categories;
        _accounts = accounts;
        _ledgers = ledgers;
        if (!_available.any((c) => c.id == _categoryId))
          _categoryId = _available.isEmpty ? null : _available.first.id;
        if (!_accounts.any((a) => a.id == _accountId)) _accountId = null;
        if (!_ledgers.any((l) => l.id == _ledgerId))
          _ledgerId = _ledgers.isEmpty ? null : _ledgers.first.id;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '分类或账户加载失败，请重试';
        });
    }
  }

  Future<void> _editCategory([Category? category]) async {
    if (_userId == null) return;
    final saved = await showDialog<Category>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecordCategoryDialog(
        type: _type,
        userId: _userId!,
        category: category,
      ),
    );
    if (saved == null || !mounted) return;
    setState(() {
      final index = _categories.indexWhere((c) => c.id == saved.id);
      if (index < 0) {
        _categories.add(saved);
      } else {
        _categories[index] = saved;
      }
      _categoryId = saved.id;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已保存分类「${saved.name}」')));
  }

  Future<void> _createAccount() async {
    if (_creatingAccount) return;
    setState(() => _creatingAccount = true);
    Map<String, dynamic>? result;
    try {
      result = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => const EditAccountPage()),
      );
    } finally {
      if (mounted) setState(() => _creatingAccount = false);
    }
    if (result == null || !mounted) return;
    final created = result['account'];
    if (created is AssetAccount) {
      // Display the committed account immediately, even if a subsequent reload fails.
      _accountsRequest++;
      setState(() {
        final index = _accounts.indexWhere(
          (account) => account.id == created.id,
        );
        if (index < 0) {
          _accounts.add(created);
        } else {
          _accounts[index] = created;
        }
        _accountId = created.id;
      });
      final message = result['existing'] == true ? '已选中' : '已保存并选中';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$message「${created.name}」')));
    }
    await _reloadAccounts();
  }

  void _onAccountsChanged() {
    if (!_creatingAccount && !_loading) _reloadAccounts();
  }

  Future<void> _reloadAccounts() async {
    final request = ++_accountsRequest;
    try {
      final accounts = await _db.getAllAssetAccounts(userId: _userId);
      if (!mounted || request != _accountsRequest) return;
      setState(() {
        _accounts = accounts;
        if (!_accounts.any((account) => account.id == _accountId))
          _accountId = null;
      });
    } catch (_) {
      if (mounted && request == _accountsRequest) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('账户列表刷新失败，已保存的账户仍可使用，请稍后重试')),
        );
      }
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final record = ExpenseRecord(
      id: widget.record?.id,
      ledgerId: _ledgerId!,
      type: _type,
      amount: double.parse(_amount.text.trim()),
      categoryId: _categoryId!,
      assetAccountId: _accountId,
      date: _date,
      title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      userId: _userId,
      cloudId: widget.record?.cloudId,
      importKey: widget.record?.importKey,
      refundGrossCents: widget.record?.refundGrossCents,
      refundTotalCents: widget.record?.refundTotalCents,
      refundBasis: widget.record?.refundBasis,
    );
    try {
      if (widget.record == null) {
        await _db.insertRecord(record);
      } else {
        await _db.updateRecord(record);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
      }
      return;
    }
    if (!mounted) return;
    // The database save already succeeded; a refresh failure must not encourage a duplicate save.
    try {
      widget.onRecordAdded?.call();
    } catch (_) {
      /* Reload on returning to the list. */
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200, 12, 31),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Widget _sectionTitle(String text, String action, VoidCallback onPressed) =>
      Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.add, size: 18),
            label: Text(action),
          ),
        ],
      );

  Widget _categoriesSection() => FormField<int>(
    key: ValueKey('categories-$_type-$_categoryId'),
    initialValue: _categoryId,
    validator: (_) => _categoryId == null ? '请选择分类，或新建一个分类' : null,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('选择分类', '新建分类', () => _editCategory()),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _available.map((category) {
            final selected = _categoryId == category.id;
            final theme = Theme.of(context);
            final scheme = theme.colorScheme;
            final color = scheme.primary;
            return SizedBox(
              width: 76,
              child: Material(
                color: selected
                    ? (theme.brightness == Brightness.dark
                          ? scheme.primaryContainer
                          : color.withValues(alpha: .12))
                    : scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: selected ? color : scheme.outlineVariant,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _categoryId = category.id),
                  onLongPress: () => _editCategory(category),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          categoryIcons[categoryIconKey(
                            category.name,
                            category.icon,
                          )],
                          color: color,
                          size: 26,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: selected ? color : scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (field.hasError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              field.errorText!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );

  Widget _formContent() => Form(
    key: _form,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (widget.record?.refundGrossCents != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '原付款 ¥${(widget.record!.refundGrossCents! / 100).toStringAsFixed(2)} · '
                '累计退款 ¥${((widget.record!.refundTotalCents ?? 0) / 100).toStringAsFixed(2)}。'
                '下方是实际净额；手动修改金额后，后续退款会交给你核对。',
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (widget.initialRecord != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('请核对金额、分类和账户，保存后才会记入账单。'),
                  ...widget.initialHints.map(
                    (hint) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(hint),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 56,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              textStyle: const TextStyle(fontSize: 17),
              minimumSize: const Size(0, 56),
            ),
            segments: const [
              ButtonSegment(value: 'expense', label: Text('支出')),
              ButtonSegment(value: 'income', label: Text('收入')),
            ],
            selected: {_type},
            onSelectionChanged: (selection) => setState(() {
              _type = selection.first;
              _categoryId = _available.isEmpty ? null : _available.first.id;
            }),
          ),
        ),
        const SizedBox(height: 22),
        TextFormField(
          controller: _title,
          autofocus: widget.record == null,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: '账单名称',
            hintText: '例如：午餐、工资',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.normal,
            color: _type == 'expense'
                ? const Color(0xFFE76B4A)
                : const Color(0xFF169B83),
          ),
          decoration: const InputDecoration(
            labelText: '金额',
            prefixText: '¥ ',
            hintText: '0.00',
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          validator: (value) {
            final input = value?.trim() ?? '';
            final amount = double.tryParse(input);
            final zeroRefund =
                widget.record?.amount == 0 &&
                widget.record?.refundGrossCents != null &&
                widget.record?.refundGrossCents ==
                    widget.record?.refundTotalCents &&
                _type == 'expense';
            return amount == null ||
                    !amount.isFinite ||
                    amount < 0 ||
                    (amount == 0 && !zeroRefund) ||
                    !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(input)
                ? '请输入正数金额，最多两位小数'
                : null;
          },
        ),
        const SizedBox(height: 16),
        _categoriesSection(),
        const SizedBox(height: 20),
        _sectionTitle(
          _type == 'expense' ? '付款账户' : '收款账户',
          '新建账户',
          _createAccount,
        ),
        DropdownButtonFormField<int>(
          key: ValueKey('account-$_accountId-${_accounts.length}'),
          initialValue: _accountId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '账户'),
          items: [
            const DropdownMenuItem<int>(value: null, child: Text('不关联账户')),
            ..._accounts.map(
              (a) => DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
            ),
          ],
          onChanged: (value) => setState(() => _accountId = value),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _ledgerId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '账本'),
          items: _ledgers
              .map((l) => DropdownMenuItem(value: l.id, child: Text(l.name)))
              .toList(),
          onChanged: (value) => setState(() => _ledgerId = value),
          validator: (value) => value == null ? '请选择账本' : null,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _pickDate,
          icon: const Icon(Icons.calendar_today_outlined, size: 19),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          label: Text('${_date.year}年${_date.month}月${_date.day}日'),
        ),
        const SizedBox(height: 18),

        TextFormField(
          controller: _note,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '备注（可选）'),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              _saving ? '保存中…' : '保存${_type == 'expense' ? '支出' : '收入'}',
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.initialRecord != null
            ? '确认语音账单'
            : widget.record == null
            ? '记一笔'
            : '编辑账单',
      ),
    ),
    body: SafeArea(
      top: false,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _loadOptions, child: const Text('重试')),
                ],
              ),
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: AbsorbPointer(absorbing: _saving, child: _formContent()),
              ),
            ),
    ),
  );
}
