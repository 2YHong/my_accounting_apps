import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/category.dart';
import '../components/category_style.dart';

class RecordCategoryDialog extends StatefulWidget {
  final String type;
  final int userId;
  final Category? category;
  const RecordCategoryDialog({super.key, required this.type, required this.userId, this.category});

  @override
  State<RecordCategoryDialog> createState() => _RecordCategoryDialogState();
}

class _RecordCategoryDialogState extends State<RecordCategoryDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late String _icon;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category?.name ?? '');
    _icon = categoryIconKey(widget.category?.name ?? '', widget.category?.icon);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    final category = Category(
      id: widget.category?.id, name: _name.text.trim(), type: widget.type,
      icon: _icon, color: widget.category?.color, userId: widget.userId,
      isSystem: widget.category?.isSystem ?? 0, parentId: widget.category?.parentId,
    );
    try {
      final db = DatabaseHelper();
      final categories = await db.getAllCategories(userId: widget.userId, type: widget.type);
      if (categories.any((c) => c.id != category.id && c.name.trim() == category.name)) {
        if (mounted) setState(() { _saving = false; _error = '这个名称已经存在'; });
        return;
      }
      if (category.id == null) {
        category.id = await db.insertCategory(category);
      } else {
        await db.updateCategory(category);
      }
    } catch (_) {
      if (mounted) setState(() { _saving = false; _error = '保存失败，请重试'; });
      return;
    }
    if (mounted) Navigator.of(context).pop(category);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.category == null ? '新建分类' : '修改分类'),
      content: SizedBox(
        width: 360,
        child: AbsorbPointer(
          absorbing: _saving,
          child: Form(key: _form, child: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(controller: _name, autofocus: true, maxLength: 20,
                decoration: const InputDecoration(labelText: '分类名称', hintText: '例如：咖啡'),
                validator: (value) => (value?.trim().isEmpty ?? true) ? '请输入分类名称' : null),
              const SizedBox(height: 12),
              const Text('选择图标'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: categoryIcons.entries.map((entry) {
                final selected = _icon == entry.key;
                return SizedBox(width: 48, height: 48, child: IconButton(
                  tooltip: entry.key,
                  style: IconButton.styleFrom(
                    backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                    foregroundColor: selected ? Theme.of(context).colorScheme.onPrimaryContainer : Theme.of(context).colorScheme.onSurfaceVariant,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  icon: Icon(entry.value, size: 24), onPressed: () => setState(() => _icon = entry.key)));
              }).toList()),

              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            ],
          ))),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? '保存中…' : '保存')),
      ],
    ),
  );
}
