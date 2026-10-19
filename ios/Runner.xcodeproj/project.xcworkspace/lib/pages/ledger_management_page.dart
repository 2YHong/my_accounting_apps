import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/ledger.dart';
import 'ledger_management_dialog.dart';

class LedgerManagementPage extends StatefulWidget {
  const LedgerManagementPage({super.key});
  @override
  State<LedgerManagementPage> createState() => _LedgerManagementPageState();
}

class _LedgerManagementPageState extends State<LedgerManagementPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _dbHelper = DatabaseHelper();
  List<Ledger> _ledgers = [];
  int? _userId;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLedgers();
  }

  Future<void> _loadLedgers() async {
    try {
      final user = await _dbHelper.getCurrentUser();
      final ledgers = await _dbHelper.getAllLedgers(userId: user.id);
      if (!mounted) return;
      setState(() { _userId = user.id; _ledgers = ledgers; _loading = false; _error = null; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = '账本加载失败，请重试'; });
    }
  }

  Future<void> _edit([Ledger? ledger]) async {
    if (_busy || _userId == null) return;
    setState(() => _busy = true);
    // The shared editor emits the global revision after its database write.
    final saved = await showLedgerEditor(context: context,
      dbHelper: _dbHelper, userId: _userId!, ledger: ledger);
    if (!mounted) return;
    if (saved != null) {
      setState(() {
        final index = _ledgers.indexWhere((item) => item.id == saved.id);
        if (index < 0) { _ledgers.add(saved); } else { _ledgers[index] = saved; }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存「${saved.name}」')));
    }
    setState(() => _busy = false);
  }

  Future<void> _delete(Ledger ledger) async {
    if (_busy) return;
    setState(() => _busy = true);
    // Deletion emits the same revision only after the transaction commits.
    final deleted = await confirmDeleteEmptyLedger(context: context,
      dbHelper: _dbHelper, ledger: ledger);
    if (!mounted) return;
    setState(() {
      if (deleted) _ledgers.removeWhere((item) => item.id == ledger.id);
      _busy = false;
    });
    if (deleted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除「${ledger.name}」')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('账本管理')),
      body: _loading ? const Center(child: CircularProgressIndicator())
        : _error != null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!), TextButton(onPressed: _loadLedgers, child: const Text('重试')),
          ]))
        : Align(alignment: Alignment.topCenter, child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: RefreshIndicator(onRefresh: _loadLedgers, child: ListView(
              physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20),
              children: [
                if (_ledgers.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Column(children: [Icon(Icons.menu_book_outlined, size: 56, color: scheme.primary),
                    const SizedBox(height: 16), const Text('创建你的第一个账本')])),
                ..._ledgers.map((ledger) {
                  final description = ledgerDescriptionForDisplay(ledger);
                  return Card(margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(contentPadding: const EdgeInsets.only(left: 20, right: 8),
                      leading: Icon(ledger.isDefault == 1 ? Icons.auto_stories_outlined : Icons.book_outlined,
                        color: scheme.primary),
                      title: Wrap(spacing: 8, runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text(ledger.name), if (ledger.isDefault == 1)
                            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8)),
                              child: Text('默认', style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer))),
                        ]),
                      subtitle: description == null ? null : Text(description),
                      onTap: _busy ? null : () => _edit(ledger),
                      trailing: PopupMenuButton<String>(enabled: !_busy, tooltip: '账本操作',
                        onSelected: (action) { if (action == 'edit') { _edit(ledger); } else { _delete(ledger); } },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑账本')),
                          if (ledger.isDefault != 1) PopupMenuItem(value: 'delete',
                            child: Text('删除账本', style: TextStyle(color: scheme.error))),
                        ]),
                    ));
                }),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: _busy || _userId == null ? null : () => _edit(),
                  icon: const Icon(Icons.add), label: const Text('新建账本'),
                  style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50))),
              ],
            )),
          )),
    );
  }
}
