import 'package:url_launcher/url_launcher.dart';

import '../sync/revision_crypto.dart';
import '../sync/vault_key_store.dart';

typedef RecoveryDraftLauncher = Future<bool> Function(Uri uri);

/// Only opens a local mail composer. There is no SMTP or accounting API call,
/// no automatic send, and no file or log containing a recovery code.
class RecoveryEmailBackup {
  final RecoveryDraftLauncher? launcher;
  const RecoveryEmailBackup({this.launcher});

  static bool validRecipient(String value) {
    final email = value.trim();
    return email.length <= 254 &&
        !RegExp(r'[\s,;<>]').hasMatch(email) &&
        RegExp(r'^[^@]+@[^@.]+(?:\.[^@.]+)+$').hasMatch(email);
  }

  Future<Uri> draft({
    required LocalVault vault,
    required String recoveryCode,
    required String recipient,
    String? accountEmail,
  }) async {
    if (!validRecipient(recipient)) {
      throw const SyncCryptoException('请输入一个有效的收件邮箱');
    }
    final code = recoveryCode.trim();
    final recovered = await RecoveryCrypto.unwrap(vault.recoveryEnvelope, code);
    if (!constantTimeEqual(
      await recovered.extractBytes(),
      await vault.key.extractBytes(),
    )) {
      throw const SyncCryptoException('恢复码与本机密钥不匹配');
    }
    final account = accountEmail?.trim() ?? '';
    final body = [
      '这是“我的记账本”的加密云同步恢复码，请妥善保存。',
      if (account.isNotEmpty) '云账号：$account',
      '',
      '恢复码：',
      code,
      '',
      '换手机时，先在软件中登录对应云账号，再连接加密空间并输入此恢复码。',
      '恢复码不是账号密码，也不是完整备份文件的密码。',
      '恢复码只能解密仍然存在的云端数据，不能找回已经丢失的账单文件。',
      '请勿转发。能登录账号并持有恢复码的人可以解密云端账单。',
    ].join('\n');
    final fields = {'subject': '我的记账本：恢复码备份', 'body': body};
    // mailto needs %20 rather than form-encoded '+' for spaces and newlines.
    final query = fields.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    return Uri(scheme: 'mailto', path: recipient.trim(), query: query);
  }

  Future<bool> openDraft({
    required LocalVault vault,
    required String recoveryCode,
    required String recipient,
    String? accountEmail,
  }) async {
    final uri = await draft(
      vault: vault,
      recoveryCode: recoveryCode,
      recipient: recipient,
      accountEmail: accountEmail,
    );
    try {
      return await (launcher?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      // Plugin exceptions can embed the full URL. Never expose or log them.
      return false;
    }
  }
}
