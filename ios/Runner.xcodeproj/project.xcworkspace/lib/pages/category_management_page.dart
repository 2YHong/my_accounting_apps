import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/category.dart';
import '../components/category_style.dart';
import 'record_category_dialog.dart';

class CategoryManagementPage extends StatefulWidget {
  const CategoryManagementPage({super.key});
  @override
  State<CategoryManagementPage> createState() => _CategoryManagementPageState();
}

class _CategoryManagementPageState extends State<CategoryManagementPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _db = DatabaseHelper();
  String _type = 'expense';
  List<Category> _categories = [];
  int? _userId;
  bool _loading = true;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final user = await _db.getCurrentUser();
      final categories = await _db.getAllCategories(userId: user.id, type: _type);
      if (mounted) setState(() { _userId = user.id; _categories = categories; _loading = false; });
    } catch (_) { if (mounted) setState(() { _loading = false; _error = '分类加载失败'; }); }
  }
  Future<void> _edit([Category? category]) async {
    if (_userId == null) return;
    final saved = await showDialog<Category>(context: context, barrierDismissible: false,
      builder: (_) => RecordCategoryDialog(type: _type, userId: _userId!, category: category));
    if (saved != null && mounted) await _load();
  }
  Future<void> _delete(Category category) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('删除「${category.name}」？'), content: const Text('正在使用的分类不能删除。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))]));
    if (confirmed != true || !mounted) return;
    try {
      final database = await _db.database;
      await database.transaction((txn) async {
        for (final table in ['expense_records', 'budgets', 'asset_accounts']) {
          final references = await txn.query(table, columns: ['id'], where: 'category_id = ?', whereArgs: [category.id], limit: 1);
          if (references.isNotEmpty) throw const FormatException('分类正在被账单、预算或账户使用');
        }
        final children = await txn.query('categories', columns: ['id'], where: 'parent_id = ?', whereArgs: [category.id], limit: 1);
        if (children.isNotEmpty) throw const FormatException('请先处理下级分类');
        await txn.delete('categories', where: 'id = ? AND user_id = ?', whereArgs: [category.id, _userId]);
      });
      if (mounted) await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is FormatException ? e.message.toString() : '删除失败，请重试')));
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('分类管理'), actions: [
      IconButton(tooltip: '新建分类', onPressed: _loading ? null : () => _edit(), icon: const Icon(Icons.add))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: SegmentedButton<String>(
        segments: const [ButtonSegment(value: 'expense', label: Text('支出')),
          ButtonSegment(value: 'income', label: Text('收入')), ButtonSegment(value: 'ignore', label: Text('账户分类'))],
        selected: {_type}, onSelectionChanged: _loading ? null : (v) { setState(() => _type = v.first); _load(); })),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : _error != null ? Center(child: TextButton(onPressed: _load, child: Text('$_error，重试')))
        : ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          if (_categories.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('暂无分类'))),
          ..._categories.map((c) => Card(child: ListTile(
            leading: Icon(categoryIcons[categoryIconKey(c.name, c.icon)], color: Theme.of(context).colorScheme.primary),
            title: Text(c.name), onTap: () => _edit(c),
            trailing: IconButton(tooltip: '删除分类', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(c))))),
        ])),
    ]),
  );
}
