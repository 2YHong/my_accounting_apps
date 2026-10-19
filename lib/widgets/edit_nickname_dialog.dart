import 'package:flutter/material.dart';

/// Keep edits in the dialog until the local database confirms the write.
class EditNicknameDialog extends StatefulWidget {
  const EditNicknameDialog({
    super.key,
    required this.initialName,
    required this.onSave,
  });

  final String initialName;
  final Future<void> Function(String name) onSave;

  @override
  State<EditNicknameDialog> createState() => _EditNicknameDialogState();
}

class _EditNicknameDialogState extends State<EditNicknameDialog> {
  late final TextEditingController _input;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _input.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入昵称');
      return;
    }
    if (name.characters.length > 30) {
      setState(() => _error = '昵称不能超过30个字');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(name);
      if (mounted) Navigator.of(context).pop(name);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '昵称保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('修改昵称'),
      content: TextField(
        controller: _input,
        autofocus: true,
        readOnly: _saving,
        maxLength: 30,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: '昵称', errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存…' : '保存'),
        ),
      ],
    ),
  );
}
