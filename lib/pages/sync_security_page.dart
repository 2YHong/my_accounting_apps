import 'package:flutter/material.dart';
import '../sync/local_sync_repository.dart';
import '../sync/vault_key_store.dart';
import '../sync/revision_crypto.dart';
import '../sync/cloud_sync_store.dart';
import '../sync/pocketbase_api.dart';
import '../sync/pocket_sync_controller.dart';
import '../services/recovery_email_backup.dart';
import '../services/recovery_mail_sender.dart';
import '../widgets/recovery_mail_dialog.dart';

class SyncSecurityPage extends StatefulWidget {
  const SyncSecurityPage({
    super.key,
    this.repository,
    this.keyStore,
    this.emailBackup,
    this.mailSender,
  });
  final LocalSyncRepository? repository;
  final VaultKeyStore? keyStore;
  final RecoveryEmailBackup? emailBackup;
  final RecoveryMailSender? mailSender;
  @override
  State<SyncSecurityPage> createState() => _SyncSecurityPageState();
}

class _SyncSecurityPageState extends State<SyncSecurityPage>
    with WidgetsBindingObserver {
  late final _repository = widget.repository ?? LocalSyncRepository();
  late final _keys = widget.keyStore ?? VaultKeyStore();
  late final _email = widget.emailBackup ?? const RecoveryEmailBackup();
  late final _mailSender =
      widget.mailSender ??
      RecoveryMailSender(PocketSyncController.instance.api);
  LocalSyncStatus? _status;
  LocalVault? _vault;
  bool _busy = false;
  bool _canCreate = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _canCreate = false;
    });
    try {
      final status = await _repository.status();
      final binding = widget.repository != null
          ? null
          : await (await CloudSyncStore.open()).binding();
      final cloud = binding == null
          ? null
          : await CloudVaultKeys().load(
              status.installationScope,
              status.userId,
              binding.owner,
              binding.vault,
            );
      final vault =
          cloud ?? await _keys.load(status.installationScope, status.userId);
      if (!mounted) return;
      setState(() {
        _status = status;
        _vault = vault;
        _canCreate = vault == null;
        _message = null;
      });
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取本机加密状态，请重新打开页面；不会覆盖已有密钥。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final status = _status;
    if (_busy || !_canCreate || status == null) return;
    setState(() => _busy = true);
    try {
      final setup = await _keys.prepare();
      if (!mounted) return;
      var saved = false;
      var openingMail = false;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('保存恢复码'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '请离线抄写或保存到可信的密码管理器。不要发给别人；丢失所有授权设备和恢复码后，无法解密云端数据。',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    setup.recoveryCode,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: openingMail
                        ? null
                        : () async {
                            setDialogState(() => openingMail = true);
                            await _emailBackup(setup.vault, setup.recoveryCode);
                            if (dialogContext.mounted)
                              setDialogState(() => openingMail = false);
                          },
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('备份到邮箱'),
                  ),
                  const Text('软件可发送到已验证的登录邮箱，也可以离线抄写保存。'),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: saved,
                    onChanged: (v) => setDialogState(() => saved = v ?? false),
                    title: const Text('我已保存恢复码'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: saved
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: const Text('确认并保存密钥'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      // A full restore or user replacement invalidates the previously captured scope.
      final current = await _repository.status();
      if (current.installationScope != status.installationScope ||
          current.userId != status.userId) {
        throw const SyncCryptoException('本地数据已变化，请重新设置');
      }
      await _keys.commit(status.installationScope, status.userId, setup);
      if (mounted) setState(() => _message = '本机密钥已保存。当前仍只在本地记账，不会上传账单。');
    } catch (_) {
      if (mounted) setState(() => _message = '密钥设置未完成，请保留已显示的恢复码并刷新状态。');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  Future<bool> _emailBackup(LocalVault vault, String code) async {
    final result = await showDialog<RecoveryMailResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryMailDialog(
        sender: _mailSender,
        vault: vault,
        recoveryCode: code,
      ),
    );
    if (result == RecoveryMailResult.sent) return true;
    if (result == RecoveryMailResult.draft && mounted) {
      await _draftEmailBackup(vault, code);
    }
    return false;
  }

  Future<bool> _draftEmailBackup(LocalVault vault, String code) async {
    final account = PocketSyncController.instance.accountEmail;
    final recipient = TextEditingController(text: account ?? '');
    final form = GlobalKey<FormState>();
    var opening = false;
    String? error;
    try {
      final route = DialogRoute<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) => AlertDialog(
                title: const Text('备份恢复码到邮箱'),
                content: SingleChildScrollView(
                  child: Form(
                    key: form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '仅打开邮箱草稿，请核对收件地址后在邮箱中发送。恢复码不经过记账服务器；邮箱也会保存这份恢复凭据。',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: recipient,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          enableSuggestions: false,
                          enabled: !opening,
                          decoration: const InputDecoration(
                            labelText: '自己的收件邮箱',
                          ),
                          validator: (value) =>
                              RecoveryEmailBackup.validRecipient(value ?? '')
                              ? null
                              : '请输入一个有效的邮箱地址',
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        const Text('打开草稿不表示已发送，请在邮箱里完成发送后确认邮件已收到。'),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: opening
                        ? null
                        : () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: opening
                        ? null
                        : () async {
                            if (!form.currentState!.validate()) return;
                            setDialogState(() {
                              opening = true;
                              error = null;
                            });
                            try {
                              final opened = await _email.openDraft(
                                vault: vault,
                                recoveryCode: code,
                                recipient: recipient.text,
                                accountEmail: account,
                              );
                              if (!dialogContext.mounted) return;
                              if (opened) {
                                Navigator.pop(dialogContext, true);
                              } else {
                                setDialogState(
                                  () =>
                                      error = '无法打开邮箱应用，请先安装并设置邮箱，或离线抄写保存恢复码。',
                                );
                              }
                            } catch (_) {
                              if (dialogContext.mounted) {
                                setDialogState(
                                  () => error = '恢复码校验或邮箱草稿准备失败，请核对后重试。',
                                );
                              }
                            } finally {
                              if (dialogContext.mounted)
                                setDialogState(() => opening = false);
                            }
                          },
                    child: Text(opening ? '正在打开' : '打开邮箱草稿'),
                  ),
                ],
              ),
            ),
          );
      final result = await Navigator.of(context, rootNavigator:true).push(route);
      await route.completed;
      return result ?? false;
    } finally {
      recipient.clear();
      recipient.dispose();
    }
  }

  Future<void> _verify({bool emailBackup = false}) async {
    final vault = _vault;
    if (_busy || vault == null) return;
    final controller = TextEditingController();
    String? code;
    try {
      final route = DialogRoute<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(emailBackup ? '输入已有恢复码以备份' : '校验恢复码'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '恢复码'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('校验'),
            ),
          ],
        ),
      );
      code = await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed;
    } finally {
      controller.clear();
      controller.dispose();
    }
    if (code == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final valid = await _keys.verifyRecovery(vault, code);
      if (mounted) setState(() => _message = valid ? '恢复码与本机密钥匹配。' : '恢复码不匹配。');
      if (valid && emailBackup && mounted) {
        final opened = await _emailBackup(vault, code);
        if (opened && mounted)
          setState(() => _message = '邮件已由发信服务接受，请到登录邮箱确认收到。');
      }
    } catch (_) {
      if (mounted) setState(() => _message = '恢复码不匹配或格式有误，请核对后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selfTest() async {
    final vault = _vault;
    if (_busy || vault == null) return;
    setState(() => _busy = true);
    try {
      final context = RevisionContext(
        ownerId: 'local',
        vaultUid: vault.vaultUid,
        objectUid: newSyncId(),
        revisionUid: newSyncId(),
        parentUids: [],
        keyEpoch: 1,
      );
      final codec = RevisionCrypto();
      final encrypted = await codec.encrypt(
        {'self_test': true},
        key: vault.key,
        context: context,
      );
      final decoded = await codec.decrypt(
        encrypted,
        key: vault.key,
        context: context,
      );
      if (decoded['self_test'] != true) throw const SyncCryptoException('校验失败');
      if (mounted) setState(() => _message = '本机加密和解密自检通过，没有发送任何网络请求。');
    } catch (_) {
      if (mounted) setState(() => _message = '本机加密自检未通过，请保留恢复码并重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('同步加密与恢复码'),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: '刷新状态',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '这里管理本机解密密钥和恢复码。首次登录后仍需连接加密空间，才会开启云同步。'
              '本地账单保存在原有数据库；上传加密不等于整库加密。',
            ),
          ),
        ),
        const SizedBox(height: 12),
        ListTile(
          title: const Text('本机加密密钥'),
          subtitle: Text(_vault == null ? '尚未设置或无法读取' : '已保存在系统安全存储'),
        ),
        ListTile(
          title: const Text('待同步变化'),
          subtitle: Text(
            _status == null
                ? '正在读取'
                : '${_status!.pendingCount} 个对象（连续修改会合并计数）',
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_message!),
          ),
        const SizedBox(height: 12),
        if (_vault == null)
          FilledButton(
            onPressed: _busy || !_canCreate ? null : _create,
            child: const Text('生成本机密钥与恢复码'),
          ),
        if (_vault != null) ...[
          FilledButton(
            onPressed: _busy ? null : () => _verify(),
            child: const Text('校验恢复码'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _verify(emailBackup: true),
            icon: const Icon(Icons.email_outlined),
            label: const Text('备份恢复码到邮箱'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _selfTest,
            child: const Text('本机加密自检'),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          '新手机需登录原账号并用恢复码解锁加密空间。原恢复码不会在本机明文留存，已有密钥的设备若要备份到邮箱，需要输入原恢复码。'
          '恢复码遗失但还能看到账单时，请先使用“备份与恢复”导出带密码的完整备份；完整备份密码与恢复码不同。',
        ),
      ],
    ),
  );
}
