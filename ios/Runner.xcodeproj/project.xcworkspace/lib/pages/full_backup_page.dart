import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/data_restore_notifications.dart';
import '../services/full_backup_service.dart';

class FullBackupPage extends StatefulWidget {
  const FullBackupPage({super.key});

  @override
  State<FullBackupPage> createState() => _FullBackupPageState();
}

class _FullBackupPageState extends State<FullBackupPage> {
  final _service = FullBackupService();
  bool _busy = false;
  String? _status;
  bool _failed = false;
  FullBackupSnapshot? _preview;
  String? _previewName;

  String _dateText(DateTime value) {
    final date = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  String _fileName(DateTime value) {
    final date = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '记账本_${date.year}${two(date.month)}${two(date.day)}_'
        '${two(date.hour)}${two(date.minute)}${two(date.second)}.accountingbackup';
  }

  Future<void> _run(Future<void> Function() action, {
    String failureMessage = '操作未完成，请检查文件是否可读取或保存，再重试。',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
      _failed = false;
    });
    try {
      await action();
    } on FullBackupException catch (error) {
      if (mounted) {
        setState(() {
          _status = error.message;
          _failed = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = failureMessage;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _password({required bool creating}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackupPasswordDialog(creating: creating),
    );
  }

  Future<void> _export() => _run(() async {
        final password = await _password(creating: true);
        if (password == null || !mounted) return;
        final snapshot = await _service.capture();
        final bytes = await _service.encrypt(snapshot, password);
        if (!mounted) return;
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存密码加密的完整备份',
          fileName: _fileName(snapshot.createdAt),
          type: FileType.any,
          bytes: bytes,
        );
        if (!mounted) return;
        setState(() {
          _status = path == null
              ? '已取消保存，没有创建备份文件。'
              : '完整备份已保存。恢复时需要输入刚才设置的密码。\n保存位置：$path';
        });
      }, failureMessage: '备份未完成，请重新选择可保存的位置。');

  Future<Uint8List> _readEncryptedFile(PlatformFile file) async {
    final limit = FullBackupService.maxEncryptedBytes;
    if (file.size <= 0 || file.size > limit) {
      throw FullBackupException('文件为空或超过 96 MB，请选择本软件导出的完整备份。');
    }
    final available = file.bytes;
    if (available != null) {
      if (available.isEmpty || available.length > limit) {
        throw FullBackupException('文件为空或超过 96 MB，请选择本软件导出的完整备份。');
      }
      return available;
    }
    final path = file.path;
    if (path != null) {
      final selected = File(path);
      final length = await selected.length();
      if (length <= 0 || length > limit) {
        throw FullBackupException('文件为空或超过 96 MB，请选择本软件导出的完整备份。');
      }
      // Stream the encrypted file with a hard bound if a provider changes it.
      return _readBounded(selected.openRead(), limit);
    }
    final stream = file.readStream;
    if (stream != null) return _readBounded(stream, limit);
    throw FullBackupException('无法读取文件，请先将备份保存到手机“文件”或“下载”目录。');
  }

  Future<Uint8List> _readBounded(Stream<List<int>> stream, int limit) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > limit) {
        throw FullBackupException('文件超过 96 MB，请选择本软件导出的完整备份。');
      }
      builder.add(chunk);
    }
    if (length == 0) throw FullBackupException('备份文件为空，无法恢复。');
    return builder.takeBytes();
  }

  Future<void> _selectBackup() => _run(() async {
        setState(() {
          _preview = null;
          _previewName = null;
        });
        final selected = await FilePicker.platform.pickFiles(
          dialogTitle: '选择完整备份文件',
          type: FileType.any,
          allowMultiple: false,
          withData: false,
          withReadStream: true,
        );
        if (selected == null || !mounted) return;
        final file = selected.files.single;
        final bytes = await _readEncryptedFile(file);
        if (!mounted) return;
        final password = await _password(creating: false);
        if (password == null || !mounted) return;
        final snapshot = await _service.open(bytes, password);
        if (!mounted) return;
        setState(() {
          _preview = snapshot;
          _previewName = file.name;
          _status = '备份已解密并通过检查。请核对下方内容，本机数据尚未改变。';
        });
      }, failureMessage: '无法打开备份，请检查密码是否正确，以及文件是否为本软件导出的完整备份。本机数据尚未改变。');

  Future<void> _restore() => _run(() async {
        final snapshot = _preview;
        if (snapshot == null) return;
        final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('替换本机数据并恢复？'),
            content: SingleChildScrollView(
              child: Text('将使用 ${_dateText(snapshot.createdAt)} 的备份替换本机全部记账数据和设置。\n\n'
                  '这是替换，不是合并。当前账单、账户余额、账本、分类、预算、待核对记录、固定收支和退款历史都会被备份中的内容替换。\n\n'
                  '如需保留当前数据，请先取消并导出一份完整备份。'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('替换并恢复'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await _service.restore(snapshot);
        if (mounted) {
          setState(() {
            _preview = null;
            _previewName = null;
            _status = '完整备份恢复成功。账单、账户、设置及待核对记录已恢复。';
          });
        }
        notifyDataRestored();
      });

  Widget _actionCard({
    required IconData icon,
    required String title,
    required String detail,
    required String label,
    required VoidCallback action,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 10),
            Text(detail),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _busy ? null : action, child: Text(label)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(FullBackupSnapshot snapshot) {
    const labels = {
      'expense_records': '账单',
      'asset_accounts': '资产账户',
      'ledgers': '账本',
      'categories': '分类',
      'budgets': '预算',
      'import_reviews': '待核对及核对历史',
      'recurring_bills': '固定收支',
      'recurring_occurrences': '固定收支确认历史',
      'refund_sources': '退款关联交易',
      'refund_events': '退款明细',
      'tags': '历史标签',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('恢复预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(_previewName ?? '完整备份', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Text('备份时间：${_dateText(snapshot.createdAt)}'),
            const Divider(height: 24),
            ...labels.entries.map((entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(child: Text(entry.value)),
                    Text('${snapshot.rowCounts[entry.key] ?? 0} 项'),
                  ]),
                )),
            const SizedBox(height: 8),
            const Text('包含个人资料、账户余额、主题、金额隐藏和固定收支提醒设置。'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore_rounded),
                label: const Text('确认恢复此备份'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('完整备份与恢复')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _actionCard(
              icon: Icons.lock_outline_rounded,
              title: '密码加密备份',
              detail: '将账单、账户余额、账本、分类、预算、待核对记录、固定收支、退款历史和个人设置一起备份。无需登录或联网。',
              label: '设置密码并保存完整备份',
              action: _export,
            ),
            _actionCard(
              icon: Icons.restore_page_outlined,
              title: '从完整备份恢复',
              detail: '选择 .accountingbackup 文件并输入密码，先查看备份内容，再确认是否替换本机数据。CSV 或 Excel 账单请使用“账单导入导出”。',
              label: '选择备份并查看内容',
              action: _selectBackup,
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Column(children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('正在处理，请等待完成后再离开。'),
                ]),
              ),
            if (_status != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_status!, style: _failed ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
                ),
              ),
            if (_preview != null) _summary(_preview!),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 24),
              child: Text('备份文件和密码请分开妥善保存。备份密码不保存在软件中，遗忘后无法恢复。\n\n'
                  'CSV 导出只包含账单；完整备份可在没有云登录和同步的情况下恢复本机数据。'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.creating});

  final bool creating;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _showPassword = false;
  bool _showConfirmation = false;

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(context, _password.text);
  }

  Widget _visibilityButton({required bool visible, required VoidCallback toggle}) {
    return IconButton(
      tooltip: visible ? '隐藏密码' : '显示密码',
      icon: Icon(visible ? Icons.visibility_outlined : Icons.visibility_off_outlined),
      onPressed: toggle,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.creating ? '设置备份密码' : '输入备份密码'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.creating
                  ? '请输入 8～128 个字符，并记好密码。'
                  : '请输入导出这份备份时设置的密码。'),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                autofocus: true,
                obscureText: !_showPassword,
                enableSuggestions: false,
                autocorrect: false,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: widget.creating ? TextInputAction.next : TextInputAction.done,
                onFieldSubmitted: widget.creating ? null : (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '备份密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: _visibilityButton(
                    visible: _showPassword,
                    toggle: () => setState(() => _showPassword = !_showPassword),
                  ),
                ),
                validator: (value) {
                  final length = (value ?? '').runes.length;
                  return length < 8 || length > 128 ? '密码需要 8～128 个字符' : null;
                },
              ),
              if (widget.creating) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmation,
                  obscureText: !_showConfirmation,
                  enableSuggestions: false,
                  autocorrect: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '再次输入密码',
                    border: const OutlineInputBorder(),
                    suffixIcon: _visibilityButton(
                      visible: _showConfirmation,
                      toggle: () => setState(() => _showConfirmation = !_showConfirmation),
                    ),
                  ),
                  validator: (value) => value == _password.text ? null : '两次输入的密码不一致',
                ),
              ],
              const SizedBox(height: 16),
              const Text('密码不会保存在软件中。遗忘密码后无法恢复备份，请自行妥善保存。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: Text(widget.creating ? '选择位置并保存' : '解密并预览')),
      ],
    );
  }
}
