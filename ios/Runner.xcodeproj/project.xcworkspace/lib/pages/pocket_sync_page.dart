import '../widgets/email_code_dialog.dart';
import 'package:flutter/material.dart';
import '../sync/pocket_sync_controller.dart';
import '../sync/sync_protocol.dart';
import 'sync_security_page.dart';

class PocketSyncPage extends StatefulWidget {
  final bool accountOnly;
  const PocketSyncPage({super.key, this.accountOnly = false});
  @override
  State<PocketSyncPage> createState() => _PocketSyncPageState();
}

class _PocketSyncPageState extends State<PocketSyncPage> {
  final controller = PocketSyncController.instance;
  final email = TextEditingController(),
      password = TextEditingController(),
      recovery = TextEditingController();
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    controller.initialize();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    email.dispose();
    password.dispose();
    recovery.dispose();
    super.dispose();
  }

  Future<void> _login(bool register) async {
    final secret = password.text;
    final address = email.text.trim();
    if (register) {
      if (address.isEmpty || secret.length < 8) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请填写邮箱，密码至少 8 位。')));
        return;
      }
      password.clear();
      final verified = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EmailCodeDialog(
          email: address,
          request: () =>
              controller.api.registerForVerification(address, secret),
          confirm: controller.api.confirmEmailCode,
        ),
      );
      if (verified != true || !mounted) return;
    } else {
      password.clear();
    }
    await controller.login(address, secret);
  }

  Future<void> _verifyOwnEmail() async {
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EmailCodeDialog(
        email: controller.accountEmail ?? '',
        request: controller.api.requestOwnEmailCode,
        confirm: controller.api.confirmEmailCode,
      ),
    );
    if (verified == true) await controller.refreshEmailVerification();
  }

  Future<void> _connect() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接并开启加密同步'),
        content: const Text(
          '这会将本机账单等数据加密后上传，并下载、合并此账号的云端数据。'
          '服务器保存密文及同步信息；若另行选择邮件备份恢复码，发信服务会接触恢复码。'
          '本机与云端不同的记录都会保留，冲突需由你选择。'
          '开启后回到前台会自动同步；请先保留一份完整备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('同意并连接'),
          ),
        ],
      ),
    );
    if (consent != true) return;
    final code = recovery.text;
    recovery.clear();
    await controller.connect(recoveryCode: code);
    if (controller.connected) await controller.sync();
  }

  String _summary(Map<String, dynamic> payload) {
    if (payload['deleted'] == true) return '删除此记录';
    final values = payload['values'] as Map? ?? {};
    final title = values['title'] ?? values['name'] ?? values['note'] ?? '记录';
    final amount =
        values['amount'] ??
        values['balance'] ??
        (values['amount_cents'] is num
            ? (values['amount_cents'] as num) / 100
            : null);
    return title.toString() +
        (amount == null ? '' : '\n金额/数值：$amount') +
        (values['date'] == null ? '' : '\n日期：${values['date']}') +
        (values['note'] == null ? '' : '\n备注：${values['note']}');
  }

  Future<void> _choose(SyncConflict conflict, int index) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认保留这个版本？'),
        content: Text(
          '${_summary(conflict.choices[index])}\n\n选择后会生成合并版本，双方历史密文仍保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认选择'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.resolve(conflict, index);
  }

  void _openAccount() => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PocketSyncPage(accountOnly: true)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.accountOnly ? '账号登录' : '云同步')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (controller.busy) const LinearProgressIndicator(),
        if (widget.accountOnly) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('填写邮箱密码，收到邮件后输入 6 位验证码；验证成功后登录。登录后可在云同步中连接加密空间。'),
          ),
          if (controller.owner == null) ...[
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '邮箱'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: controller.busy ? null : () => _login(false),
              child: const Text('登录'),
            ),
            TextButton(
              onPressed: controller.busy ? null : () => _login(true),
              child: const Text('注册并获取验证码'),
            ),
            TextButton(
              onPressed: controller.busy ? null : () => _login(true),
              child: const Text('验证已有注册邮箱'),
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(controller.accountEmail ?? '云账号已登录'),
            ),
            ListTile(
              leading: Icon(
                controller.api.emailVerified == true
                    ? Icons.verified_outlined
                    : Icons.mark_email_unread_outlined,
              ),
              title: Text(
                controller.api.emailVerified == true ? '邮箱已验证' : '邮箱尚未验证',
              ),
              subtitle: const Text('验证一次后，发送恢复码无需重复验证。'),
            ),
            if (controller.api.emailVerified != true) ...[
              TextButton(
                onPressed: controller.busy ? null : _verifyOwnEmail,
                child: const Text('填写邮箱验证码'),
              ),
              TextButton(
                onPressed: controller.busy
                    ? null
                    : controller.refreshEmailVerification,
                child: const Text('已验证，刷新状态'),
              ),
            ],
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PocketSyncPage()),
                    ),
              child: const Text('前往云同步'),
            ),
            TextButton(
              onPressed: controller.busy ? null : controller.logout,
              child: const Text('退出云账号'),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(controller.message),
          ),
        ] else ...[
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '账单在设备上加密后上传。若选择邮件备份恢复码，发信服务器和邮件服务会接触该码。'
                '新手机登录同一账号，使用原恢复码解锁。退出登录不会删除云端数据。',
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              controller.owner == null
                  ? '尚未登录'
                  : (controller.accountEmail ?? '云账号已登录'),
            ),
            trailing: TextButton(
              onPressed: controller.busy ? null : _openAccount,
              child: Text(controller.owner == null ? '去登录' : '管理账号'),
            ),
          ),
          Text('加密空间：${controller.connected ? '已连接' : '待连接'}'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('账单同步：${controller.message}'),
          ),
          if (controller.owner != null) ...[
            if (!controller.connected) ...[
              TextField(
                controller: recovery,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '原恢复码（新设备解锁时填写）'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: controller.busy ? null : _connect,
                child: const Text('连接并开启加密同步'),
              ),
            ] else
              FilledButton(
                onPressed: controller.busy ? null : controller.sync,
                child: const Text('立即同步'),
              ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.enhanced_encryption_outlined),
            title: const Text('加密与恢复码'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SyncSecurityPage())),
          ),
          for (final conflict in controller.conflicts)
            Card(
              child: ExpansionTile(
                title: Text(
                  '待处理冲突：${const {'expense_records': '账单', 'ledgers': '账本', 'categories': '分类', 'asset_accounts': '资产账户', 'budgets': '预算', 'tags': '标签', 'record_tags': '账单标签', 'import_reviews': '导入核对', 'recurring_bills': '固定收支模板', 'recurring_occurrences': '固定收支本期状态', 'refund_sources': '退款来源', 'refund_events': '退款事件'}[conflict.choices.first['entity']] ?? '记录'}',
                ),
                subtitle: Text('${conflict.heads.length} 个版本，包含编辑或删除'),
                children: [
                  for (var i = 0; i < conflict.heads.length; i++)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_summary(conflict.choices[i])),
                          Text(
                            '云端版本 ${conflict.heads[i].changeSeq?.toString() ?? '待上传'}',
                          ),
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () => _choose(conflict, i),
                            child: const Text('保留此版本'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}
