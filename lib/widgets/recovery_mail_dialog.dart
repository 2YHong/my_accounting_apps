import 'email_code_dialog.dart';
import 'package:flutter/material.dart';
import '../services/recovery_mail_sender.dart';
import '../sync/pocketbase_api.dart';
import '../sync/vault_key_store.dart';

enum RecoveryMailResult { sent, draft }

class RecoveryMailDialog extends StatefulWidget {
  final RecoveryMailSender sender;
  final LocalVault vault;
  final String recoveryCode;
  const RecoveryMailDialog({
    super.key,
    required this.sender,
    required this.vault,
    required this.recoveryCode,
  });
  @override
  State<RecoveryMailDialog> createState() => _RecoveryMailDialogState();
}

class _RecoveryMailDialogState extends State<RecoveryMailDialog> {
  RecoveryMailStatus? _status;
  bool _busy = true, _consent = false, _sent = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _message = null;
      _consent = false;
    });
    try {
      final value = await widget.sender.status();
      if (mounted) setState(() => _status = value);
    } catch (e) {
      if (mounted)
        setState(() {
          _status = null;
          _message = e is CloudSyncException ? e.message : '无法读取邮件服务状态，请稍后重试。';
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final status = _status;
    if (status == null || _busy) return;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EmailCodeDialog(
        email: status.email,
        request: () => widget.sender.requestVerification(status.email),
        confirm: widget.sender.confirmVerification,
      ),
    );
    if (verified == true && mounted) await _refresh();
  }

  Future<void> _send() async {
    final status = _status;
    if (_busy || !_consent || status == null) return;
    setState(() => _busy = true);
    try {
      await widget.sender.send(
        vault: widget.vault,
        recoveryCode: widget.recoveryCode,
        expectedEmail: status.email,
        consent: _consent,
      );
      if (mounted)
        setState(() {
          _sent = true;
          _message = '邮件已由发信服务接受。请核对收件箱和垃圾邮件，确认收到后再保存密钥。';
        });
    } catch (e) {
      if (mounted)
        setState(
          () => _message = e is CloudSyncException
              ? e.message
              : '发送未完成，请核对恢复码后重试。',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('发送恢复码到登录邮箱'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (status != null) ...[
                Text('收件邮箱：' + status.email),
                const SizedBox(height: 12),
                if (!status.ready) const Text('服务器尚未配置发信邮箱。配置完成后即可使用软件直接发送。'),
                if (status.ready && !status.verified) ...[
                  const Text('请先证明这个邮箱属于你。验证只用于邮件备份，不会删除本地账单。'),
                  TextButton(
                    onPressed: _busy ? null : _verify,
                    child: const Text('填写邮箱验证码'),
                  ),
                ],
                if (status.ready && status.verified && !_sent)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _consent = v ?? false),
                    title: const Text('我同意通过服务器发送恢复码'),
                    subtitle: const Text(
                      '发信服务器和邮件服务会接触恢复码，邮箱也会保存它。持有恢复码并能登录云账号的人可以解密账单。',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!),
                ),
              if (!_sent)
                TextButton(
                  onPressed: _busy ? null : _refresh,
                  child: const Text('刷新验证状态'),
                ),
            ],
          ),
        ),
        actions: [
          if (!_sent)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => Navigator.pop(context, RecoveryMailResult.draft),
              child: const Text('使用本机邮箱草稿'),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.pop(
                    context,
                    _sent ? RecoveryMailResult.sent : null,
                  ),
            child: Text(_sent ? '完成' : '取消'),
          ),
          if (!_sent && status?.ready == true && status?.verified == true)
            FilledButton(
              onPressed: _busy || !_consent ? null : _send,
              child: Text(_busy ? '正在发送' : '发送恢复码'),
            ),
        ],
      ),
    );
  }
}
