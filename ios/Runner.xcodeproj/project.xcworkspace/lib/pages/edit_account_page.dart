import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/asset_account.dart';
import '../services/asset_account_service.dart';

class EditAccountPage extends StatefulWidget {
  final AssetAccount? account;
  const EditAccountPage({super.key, this.account});
  @override
  State<EditAccountPage> createState() => _EditAccountPageState();
}

class _EditAccountPageState extends State<EditAccountPage> {
  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseHelper();
  final _service = AssetAccountService();
  late final TextEditingController _name;
  late final TextEditingController _balance;
  late final TextEditingController _cardNumber;
  late final TextEditingController _creditLimit;
  late final TextEditingController _description;
  String _type = 'digital';
  bool _working = false;
  bool _deleting = false;
  final _types = <({String value, String label, IconData icon})>[
    (
      value: 'digital',
      label: '电子钱包',
      icon: Icons.account_balance_wallet_outlined,
    ),
    (value: 'cash', label: '现金', icon: Icons.payments_outlined),
    (value: 'bank', label: '银行卡', icon: Icons.credit_card_outlined),
    (value: 'loan', label: '借贷账户', icon: Icons.account_balance_outlined),
    (value: 'investment', label: '投资账户', icon: Icons.trending_up),
    (value: 'custom', label: '自定义', icon: Icons.widgets_outlined),
  ];

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    _type = account?.type ?? 'digital';
    _name = TextEditingController(text: account?.name ?? '');
    _balance = TextEditingController(
      text: account?.balance.toStringAsFixed(2) ?? '0.00',
    );
    _cardNumber = TextEditingController(
      text: account?.cardNumberLastFour ?? '',
    );
    _creditLimit = TextEditingController(
      text: account?.creditLimit?.toStringAsFixed(2) ?? '',
    );
    _description = TextEditingController(text: account?.desc ?? '');
  }

  @override
  void dispose() {
    _releaseSyncEdit();
    _name.dispose();
    _balance.dispose();
    _cardNumber.dispose();
    _creditLimit.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _validateMoney(String? value, {bool optional = false}) {
    final text = value?.trim() ?? '';
    if (optional && text.isEmpty) return null;
    final amount = double.tryParse(text);
    return amount == null || !amount.isFinite ? '请输入有效的金额' : null;
  }

  void _message(String message) {
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveAccount() async {
    if (_working || !_formKey.currentState!.validate()) return;
    setState(() => _working = true);
    try {
      final user = await _db.getCurrentUser();
      final account = AssetAccount(
        id: widget.account?.id,
        name: _name.text.trim(),
        type: _type,
        balance: double.parse(_balance.text.trim()),
        desc: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        cardNumberLastFour:
            _type == 'bank' && _cardNumber.text.trim().isNotEmpty
            ? _cardNumber.text.trim()
            : null,
        creditLimit: _type == 'loan'
            ? double.tryParse(_creditLimit.text.trim())
            : null,
        userId: widget.account?.userId ?? user.id,
        icon: widget.account?.icon,
        categoryId: widget.account?.categoryId,
      );
      final original = widget.account;
      final saved = await _service.save(
        account,
        updateBalance:
            original == null ||
            _type != original.type ||
            (account.balance * 100).round() != (original.balance * 100).round(),
      );
      if (!mounted) return;
      setState(() => _working = false);
      Navigator.of(context).pop({'refresh': true, 'account': saved});
    } on DuplicateAssetAccountException catch (error) {
      if (!mounted) return;
      setState(() => _working = false);
      if (widget.account != null) {
        _message('已有同名的同类型账户，请修改名称');
        return;
      }
      final useExisting = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('这个账户已经存在'),
          content: Text('「${error.existing.name}」已经保存，无需重复添加。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('修改名称'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('使用已有账户'),
            ),
          ],
        ),
      );
      if (useExisting == true && mounted) {
        Navigator.of(
          context,
        ).pop({'refresh': true, 'existing': true, 'account': error.existing});
      }
    } catch (_) {
      _message('账户保存失败，请重试');
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_working || widget.account?.id == null) return;
    setState(() {
      _working = true;
      _deleting = true;
    });
    try {
      final count = await _service.linkedBillCount(widget.account!);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除账户'),
          content: Text(
            count == 0
                ? '确定删除「${widget.account!.name}」吗？'
                : '「${widget.account!.name}」关联了 $count 条账单。删除后账单全部保留，付款或收款账户改为“不关联账户”。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('删除账户'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _service.delete(widget.account!);
      if (mounted) {
        setState(() => _working = false);
        Navigator.of(context).pop({'deleted': true, 'refresh': true});
      }
    } catch (_) {
      _message('删除失败，请重试');
    } finally {
      if (mounted)
        setState(() {
          _working = false;
          _deleting = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.account != null;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(
          title: Text(editing ? '编辑账户' : '添加账户'),
          actions: [
            if (editing)
              TextButton.icon(
                onPressed: _working ? null : _deleteAccount,
                icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                label: Text('删除', style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: AbsorbPointer(
                absorbing: _working,
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      TextFormField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '账户名称',
                          hintText: '例如：微信、支付宝、工资卡',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请输入账户名称'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      const Text('账户类型', style: TextStyle(fontSize: 15)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _types
                            .map(
                              (type) => ChoiceChip(
                                avatar: Icon(
                                  type.icon,
                                  size: 18,
                                  color: _type == type.value
                                      ? scheme.onSecondaryContainer
                                      : scheme.onSurfaceVariant,
                                ),
                                label: Text(type.label),
                                selected: _type == type.value,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => _type = type.value),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _balance,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: InputDecoration(
                          labelText: _type == 'loan' ? '当前已借款金额' : '当前余额',
                          prefixText: '¥ ',
                          border: const OutlineInputBorder(),
                        ),
                        validator: _validateMoney,
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '关联账户的收支会自动更新余额。修改这里可以校准当前金额。',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                      if (_type == 'bank') ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _cardNumber,
                          keyboardType: TextInputType.number,
                          maxLength: 4,
                          decoration: const InputDecoration(
                            labelText: '卡号末四位（可选）',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              value == null ||
                                  value.trim().isEmpty ||
                                  RegExp(r'^\d{4}$').hasMatch(value.trim())
                              ? null
                              : '请输入四位数字',
                        ),
                      ],
                      if (_type == 'loan') ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _creditLimit,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '贷款总额（可选）',
                            prefixText: '¥ ',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              _validateMoney(value, optional: true),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _description,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        onPressed: _working ? null : _saveAccount,
                        icon: _working && !_deleting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.check, size: 20),
                        label: Text(
                          _working
                              ? (_deleting ? '删除中…' : '保存中…')
                              : (editing ? '保存修改' : '保存账户'),
                        ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 52),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
