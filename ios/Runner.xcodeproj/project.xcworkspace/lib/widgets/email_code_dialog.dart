import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sync/pocketbase_api.dart';

class EmailCodeDialog extends StatefulWidget {
  final String email;
  final Future<Map<String, dynamic>> Function() request;
  final Future<void> Function(String challenge, String code) confirm;
  const EmailCodeDialog({
    super.key,
    required this.email,
    required this.request,
    required this.confirm,
  });
  @override
  State<EmailCodeDialog> createState() => _EmailCodeDialogState();
}

class _EmailCodeDialogState extends State<EmailCodeDialog> {
  final _code = TextEditingController();
  Timer? _timer;
  String? _challenge, _error;
  bool _busy = false;
  int _remaining = 0;
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    if (_busy || _remaining > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.request();
      if (!mounted) return;
      if (r['verified'] == true) {
        Navigator.pop(context, true);
        return;
      }
      final id = r['challenge'];
      if (id is! String || !RegExp(r'^[A-Za-z0-9]{40}$').hasMatch(id)) {
        throw const CloudSyncException('验证码服务响应无效，请更新服务器后重试。');
      }
      _challenge = id;
      _code.clear();
      _remaining = 60;
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = e is CloudSyncException ? e.message : '验证码未确认发送，请稍后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final challenge = _challenge, code = _code.text.trim();
    if (_busy || challenge == null || !RegExp(r'^\d{6}$').hasMatch(code)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.confirm(challenge, code);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is CloudSyncException ? e.message : '验证未完成，请稍后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('填写邮箱验证码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('收件邮箱：${widget.email}'),
            const SizedBox(height: 12),
            const Text('请填写邮件中的 6 位数字。10 分钟内有效，最多尝试 5 次。'),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            TextField(
              controller: _code,
              autofocus: true,
              enabled: !_busy && _challenge != null,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
              decoration: const InputDecoration(labelText: '6 位验证码'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            TextButton(
              onPressed: _busy || _remaining > 0 ? null : _request,
              child: Text(
                _remaining > 0
                    ? '重新发送（$_remaining秒）'
                    : '重新发送验证码',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || _challenge == null || _code.text.length != 6
              ? null
              : _confirm,
          child: const Text('验证'),
        ),
      ],
    ),
  );
}
