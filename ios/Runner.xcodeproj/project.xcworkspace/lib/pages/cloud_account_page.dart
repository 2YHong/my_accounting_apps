import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/cloud_account_service.dart';
import '../services/full_backup_service.dart';
import '../services/data_restore_notifications.dart';

class CloudAccountPage extends StatefulWidget {
  const CloudAccountPage({super.key});
  @override
  State<CloudAccountPage> createState() => _CloudAccountPageState();
}

class _CloudAccountPageState extends State<CloudAccountPage> {
  final _cloud = CloudAccountService();
  final _backup = FullBackupService();
  final _email = TextEditingController();
  final _code = TextEditingController();
  StreamSubscription<AuthState>? _auth;
  Timer? _timer;
  bool _ready = false, _busy = false, _checked = false;
  int _cooldown = 0;
  String? _sentEmail, _owner;
  String _status = '正在准备云账号…';
  CloudSnapshot? _remote;

  @override
  void initState() {
    super.initState();
    _run(() async {
      await _cloud.initialize();
      _owner = _cloud.client.auth.currentUser?.id;
      _auth = _cloud.client.auth.onAuthStateChange.listen(
        (_) {
          if (!mounted) return;
          final next = _cloud.client.auth.currentUser?.id;
          setState(() {
            if (next != _owner) {
              _checked = false;
              _remote = null;
            }
            _owner = next;
          });
        },
        onError: (_) {
          if (mounted) {
            setState(() => _status = '登录状态刷新失败，请检查网络后重试');
          }
        },
      );
      if (mounted) {
        setState(() {
          _ready = true;
          _status = '离线记账仍可正常使用。';
        });
      }
    });
  }

  @override
  void dispose() {
    _auth?.cancel();
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      final message = error is FullBackupException
          ? error.message
          : error is PostgrestException &&
                error.message.contains('CLOUD_CONFLICT')
          ? '另一台手机已更新云备份。本次上传已取消，请重新检查云端并确认要保留的数据。'
          : error is AuthException
          ? '登录失败：请检查邮箱和验证码，或稍后重试。'
          : '操作未完成，请检查网络及云服务配置后重试。';
      setState(() {
        _status = message;
        _checked = false;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _send() => _run(() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      throw const FullBackupException('请输入有效的邮箱地址');
    }
    await _cloud.sendCode(email);
    if (!mounted) return;
    setState(() {
      _sentEmail = email;
      _cooldown = 60;
      _status = '验证码已发送，请查看邮箱；首次验证会创建账号。';
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _cooldown <= 1) {
        timer.cancel();
        if (mounted) {
          setState(() => _cooldown = 0);
        }
      } else {
        setState(() => _cooldown--);
      }
    });
  });

  Future<void> _verify() => _run(() async {
    final email = _email.text.trim();
    if (email != _sentEmail) {
      throw const FullBackupException('邮箱已改变，请重新获取验证码');
    }
    if (!RegExp(r'^\d{6,10}$').hasMatch(_code.text.trim())) {
      throw const FullBackupException('请输入邮件中的数字验证码');
    }
    await _cloud.verify(email, _code.text.trim());
    _code.clear();
    if (mounted) {
      setState(() => _status = '登录成功。本机数据不会自动上传或替换。');
    }
  });

  Future<void> _check() => _run(() async {
    final remote = await _cloud.fetch();
    if (mounted) {
      setState(() {
        _remote = remote;
        _checked = true;
        _status = remote == null
            ? '云端尚无备份，可以上传本机数据。'
            : '云备份版本 ${remote.revision}，更新于 ${remote.updatedAt.toLocal()}。';
      });
    }
  });

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(detail)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<String?> _password({required bool creating}) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CloudPasswordDialog(creating: creating),
    );
  }

  Future<void> _upload() => _run(() async {
    if (!_checked) throw const FullBackupException('请先检查云端状态');
    final owner = _cloud.uid;
    final revision = _remote?.revision ?? 0;
    final agreed = await _confirm(
      '上传本机完整数据？',
      '将本机账单、账本、资产、预算、固定收支和设置加密上传到当前账号。'
          '\n\n${revision == 0 ? '创建第一份云备份。' : '将替换云端版本 $revision；请确认另一台手机的数据已保存。'}'
          '\n\n请牢记备份密码，另一台手机恢复时需要输入。密码不会上传，遗忘后无法解密。',
    );
    if (!agreed || !mounted) return;
    final password = await _password(creating: true);
    if (password == null || !mounted) return;
    _cloud.assertUser(owner);
    final bytes = await _backup.createEncryptedBackup(password);
    await _cloud.upload(bytes, revision, owner);
    if (mounted) {
      setState(() {
        _checked = false;
        _status = '上传成功，请检查云端状态查看新版本。';
      });
    }
  });

  Future<void> _download() => _run(() async {
    final owner = _cloud.uid;
    final remote = await _cloud.fetch(withPayload: true);
    if (remote?.bytes == null) {
      throw const FullBackupException('当前账号没有可恢复的云备份');
    }
    if (!mounted) return;
    final password = await _password(creating: false);
    if (password == null || !mounted) return;
    final snapshot = await _backup.open(remote!.bytes!, password);
    _cloud.assertUser(owner);
    if (!mounted) return;
    final confirmed = await _confirm(
      '恢复云备份并替换本机数据？',
      '云版本：${remote.revision}\n备份时间：${snapshot.createdAt.toLocal()}\n'
          '账单：${snapshot.rowCounts['expense_records'] ?? 0} 条\n'
          '账本：${snapshot.rowCounts['ledgers'] ?? 0} 个\n'
          '资产账户：${snapshot.rowCounts['asset_accounts'] ?? 0} 个\n\n'
          '已解密并通过数据校验。确认后会替换本机全部记账数据和设置，不会合并。'
          '请先通过“完整备份与恢复”导出本机备份，保留未上传的数据。',
    );
    if (!confirmed || !mounted) return;
    _cloud.assertUser(owner);
    await _backup.restore(snapshot);
    notifyDataRestored();
    if (mounted) {
      setState(() {
        _checked = false;
        _status = '云备份恢复成功。';
      });
    }
  });

  Future<void> _logout() => _run(() async {
    if (!await _confirm('退出云账号？', '本机记账数据会保留。其他人登录后仍可看到本机数据，切换账号前请妥善处理个人账单。') ||
        !mounted) {
      return;
    }
    await _cloud.signOut();
    if (mounted) {
      setState(() {
        _remote = null;
        _checked = false;
        _status = '已退出云账号，本机数据已保留。';
      });
    }
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('登录与云同步')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Text(_status),
          const SizedBox(height: 20),
          if (!_ready) ...[
            const Text('配置完成后可使用邮箱验证码登录。未配置云服务时，继续使用本机记账和完整备份。'),
          ] else if (_owner == null) ...[
            TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '邮箱'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy || _cooldown > 0 ? null : _send,
              child: Text(_cooldown > 0 ? '$_cooldown 秒后重新发送' : '获取验证码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 10,
              decoration: const InputDecoration(labelText: '邮件验证码'),
            ),
            FilledButton(
              onPressed: _busy || _sentEmail == null ? null : _verify,
              child: const Text('登录 / 注册'),
            ),
          ] else ...[
            Text('当前云账号：${_cloud.client.auth.currentUser?.email ?? ''}'),
            const SizedBox(height: 12),
            const Text(
              '手动加密同步：上传会替换云备份，恢复会替换本机数据。多台手机分别新增的数据不会自动合并。备份最大 8 MB。',
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _check,
              child: const Text('检查云端状态'),
            ),
            FilledButton(
              onPressed: _busy || !_checked ? null : _upload,
              child: const Text('加密上传本机数据'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _download,
              child: const Text('下载并预览云备份'),
            ),
            TextButton(
              onPressed: _busy ? null : _logout,
              child: const Text('退出云账号'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _CloudPasswordDialog extends StatefulWidget {
  final bool creating;
  const _CloudPasswordDialog({required this.creating});
  @override
  State<_CloudPasswordDialog> createState() => _CloudPasswordDialogState();
}

class _CloudPasswordDialogState extends State<_CloudPasswordDialog> {
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _password.text;
    if (password.runes.length < 8 || password.runes.length > 128) {
      setState(() => _error = '密码需要 8 至 128 个字符');
      return;
    }
    if (widget.creating && password != _confirmation.text) {
      setState(() => _error = '两次密码不一致');
      return;
    }
    Navigator.pop(context, password);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.creating ? '设置云备份密码' : '输入云备份密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('密码仅用于加密和解密账本，不是邮箱验证码。请妥善保存，软件无法找回。'),
          TextField(
            controller: _password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '备份密码'),
          ),
          if (widget.creating)
            TextField(
              controller: _confirmation,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '再次输入密码'),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('继续')),
    ],
  );
}
