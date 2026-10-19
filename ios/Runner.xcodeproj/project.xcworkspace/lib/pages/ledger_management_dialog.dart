import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/ledger.dart';
import '../services/ledger_notifications.dart';

String? ledgerDescriptionForDisplay(Ledger ledger) {
  if (ledger.isDefault == 1) return null;
  final description = ledger.desc?.trim();
  return description == null || description.isEmpty ? null : description;
}

/// Shared editor for the home popup and the full ledger management page.
Future<Ledger?> showLedgerEditor({
  required BuildContext context,
  required DatabaseHelper dbHelper,
  required int userId,
  Ledger? ledger,
}) => showDialog<Ledger>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _LedgerEditor(dbHelper: dbHelper, userId: userId, ledger: ledger),
);

class _LedgerEditor extends StatefulWidget {
  final DatabaseHelper dbHelper;
  final int userId;
  final Ledger? ledger;
  const _LedgerEditor({required this.dbHelper, required this.userId, this.ledger});
  @override
  State<_LedgerEditor> createState() => _LedgerEditorState();
}

class _LedgerEditorState extends State<_LedgerEditor> {
  final _releaseSyncEdit = SyncEditGuard.acquire();
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.ledger?.name ?? '');
    _description = TextEditingController(
        text: widget.ledger == null ? '' : ledgerDescriptionForDisplay(widget.ledger!) ?? '');
  }

  @override
  void dispose() {
    _releaseSyncEdit();
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    final original = widget.ledger;
    final updated = Ledger(
      id: original?.id,
      name: _name.text.trim(),
      icon: original?.icon,
      isDefault: original?.isDefault ?? 0,
      desc: original?.isDefault == 1 || _description.text.trim().isEmpty
          ? null : _description.text.trim(),
      cloudId: original?.cloudId,
      userId: original?.userId ?? widget.userId,
    );
    try {
      if (updated.id == null) {
        updated.id = await widget.dbHelper.insertLedger(updated);
      } else {
        final changed = await widget.dbHelper.updateLedger(updated);
        if (changed != 1) throw StateError('账本不存在');
      }
    } catch (_) {
      if (mounted) setState(() { _saving = false; _error = '保存失败，请重试'; });
      return;
    }
    notifyLedgersChanged();
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(widget.ledger == null ? '新建账本' : '编辑账本'),
        content: SizedBox(width: 360, child: SingleChildScrollView(
          child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: _name, autofocus: true, enabled: !_saving,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '账本名称', hintText: '例如：日常生活',
                border: OutlineInputBorder()),
              validator: (value) => value == null || value.trim().isEmpty ? '请输入账本名称' : null),
            if (widget.ledger?.isDefault != 1) ...[
              const SizedBox(height: 16),
              TextFormField(controller: _description, enabled: !_saving, maxLines: 2,
                decoration: const InputDecoration(labelText: '描述（可选）',
                  border: OutlineInputBorder())),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: scheme.error))),
          ])),
        )),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消')),
          FilledButton(onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存')),
        ],
      ),
    );
  }
}

/// A ledger with bills or budgets is retained, rather than leaving dangling IDs.
Future<bool> confirmDeleteEmptyLedger({
  required BuildContext context,
  required DatabaseHelper dbHelper,
  required Ledger ledger,
}) async {
  if (ledger.isDefault == 1 || ledger.id == null) return false;
  final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
    title: const Text('删除账本'),
    content: Text('确定删除「${ledger.name}」吗？只有没有账单和预算的账本可以删除。'),
    actions: [
      TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true),
        style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
        child: const Text('删除')),
    ],
  ));
  if (confirmed != true || !context.mounted) return false;
  try {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final found = await txn.query('ledgers', columns: ['is_default'],
        where: 'id = ? AND user_id IS ?', whereArgs: [ledger.id, ledger.userId]);
      if (found.isEmpty || found.first['is_default'] == 1) {
        throw StateError('这个账本不能删除');
      }
      final bills = await txn.query('expense_records', columns: ['id'],
        where: 'ledger_id = ?', whereArgs: [ledger.id], limit: 1);
      final budgets = await txn.query('budgets', columns: ['id'],
        where: 'ledger_id = ?', whereArgs: [ledger.id], limit: 1);
      if (bills.isNotEmpty || budgets.isNotEmpty) {
        throw StateError('账本中还有账单或预算，请先迁移账单并删除预算，再删除账本。');
      }
      await txn.delete('ledgers', where: 'id = ? AND user_id IS ?',
        whereArgs: [ledger.id, ledger.userId]);
    });
    notifyLedgersChanged();
    return true;
  } catch (error) {
    if (context.mounted) {
      final message = error is StateError ? '${error.message}' : '删除失败，请重试';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    return false;
  }
}

class LedgerManagementDialog extends StatefulWidget {
  final List<Ledger> ledgers;
  final Future<void> Function() onLedgerAdded;
  final Future<void> Function() onLedgerUpdated;
  final Future<void> Function() onLedgerDeleted;
  final int userId;
  final DatabaseHelper dbHelper;
  const LedgerManagementDialog({super.key, required this.ledgers,
    required this.onLedgerAdded, required this.onLedgerUpdated,
    required this.onLedgerDeleted, required this.userId, required this.dbHelper});
  @override
  State<LedgerManagementDialog> createState() => _LedgerManagementDialogState();
}

class _LedgerManagementDialogState extends State<LedgerManagementDialog> {
  final _releaseSyncEdit = SyncEditGuard.acquire();
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  late List<Ledger> _ledgers;
  bool _busy = false;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _ledgers = List.of(widget.ledgers);
  }

  Future<void> _edit([Ledger? ledger]) async {
    if (_busy) return;
    setState(() => _busy = true);
    final saved = await showLedgerEditor(context: context, dbHelper: widget.dbHelper,
      userId: widget.userId, ledger: ledger);
    if (!mounted) return;
    if (saved == null) { setState(() => _busy = false); return; }
    setState(() {
      final index = _ledgers.indexWhere((entry) => entry.id == saved.id);
      if (index < 0) { _ledgers.add(saved); } else { _ledgers[index] = saved; }
      _feedback = '已保存「${saved.name}」';
    });
    try {
      await (ledger == null ? widget.onLedgerAdded() : widget.onLedgerUpdated());
    } catch (_) {
      if (mounted) setState(() => _feedback = '账本已保存，请重新打开首页刷新');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Ledger ledger) async {
    if (_busy) return;
    setState(() => _busy = true);
    final deleted = await confirmDeleteEmptyLedger(context: context,
      dbHelper: widget.dbHelper, ledger: ledger);
    if (!mounted) return;
    if (deleted) {
      setState(() {
        _ledgers.removeWhere((entry) => entry.id == ledger.id);
        _feedback = '已删除「${ledger.name}」';
      });
      try { await widget.onLedgerDeleted(); } catch (_) {
        if (mounted) setState(() => _feedback = '账本已删除，请重新打开首页刷新');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(canPop: !_busy, child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 20, 12, 16), child: Row(children: [
            Container(padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(14)),
              child: Icon(Icons.menu_book_outlined, color: scheme.onPrimaryContainer)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('账本管理', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 3),
              Text('${_ledgers.length} 个账本', style: TextStyle(color: scheme.onSurfaceVariant)),
            ])),
            IconButton(tooltip: '关闭', onPressed: _busy ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close)),
          ])),
          if (_feedback != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(children: [Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
              const SizedBox(width: 8), Expanded(child: Text(_feedback!))])),
          const Divider(height: 1),
          Flexible(child: _ledgers.isEmpty
            ? Padding(padding: const EdgeInsets.all(32), child: Text('暂无账本',
                style: TextStyle(color: scheme.onSurfaceVariant)))
            : ListView.separated(shrinkWrap: true, padding: const EdgeInsets.all(16),
                itemCount: _ledgers.length, separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final ledger = _ledgers[index];
                  final description = ledgerDescriptionForDisplay(ledger);
                  return Material(color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      leading: Icon(ledger.isDefault == 1 ? Icons.auto_stories_outlined : Icons.book_outlined,
                        color: scheme.primary),
                      title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center,
                        children: [Text(ledger.name), if (ledger.isDefault == 1)
                          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8)),
                            child: Text('默认', style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer)))]),
                      subtitle: description == null ? null : Text(description, maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                      onTap: _busy ? null : () => _edit(ledger),
                      trailing: PopupMenuButton<String>(enabled: !_busy, tooltip: '账本操作',
                        onSelected: (value) { if (value == 'edit') { _edit(ledger); } else { _delete(ledger); } },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑账本')),
                          if (ledger.isDefault != 1) PopupMenuItem(value: 'delete',
                            child: Text('删除账本', style: TextStyle(color: scheme.error))),
                        ]),
                    ));
                })),
          Padding(padding: const EdgeInsets.all(20), child: SizedBox(width: double.infinity,
            child: FilledButton.icon(onPressed: _busy ? null : () => _edit(),
              icon: const Icon(Icons.add), label: const Text('新建账本'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48))))),
        ]),
      ),
    ));
  }
}
