import '../sync/pocketbase_api.dart';
import '../sync/revision_crypto.dart';
import '../sync/vault_key_store.dart';

class RecoveryMailStatus {
  final String email;
  final bool verified, ready;
  const RecoveryMailStatus(
    this.email, {
    required this.verified,
    required this.ready,
  });
}

/// Explicit, opt-in server mail. Codes are never cached or automatically retried.
class RecoveryMailSender {
  final SyncTransport api;
  const RecoveryMailSender(this.api);
  static const path = '/api/accounting/v1/recovery-mail';

  Future<RecoveryMailStatus> status() async {
    final owner = api.ownerId;
    if (owner == null) throw const CloudSyncException('请先在“我的”登录云账号，再发送恢复码。');
    final result = await api.request('GET', path);
    if (api.ownerId != owner)
      throw const CloudSyncException('登录账号已变化，请重新打开邮件备份。');
    final email = result['email'];
    if (result['protocol'] != 1 || email is! String || email.isEmpty) {
      throw const CloudSyncException('邮件服务响应无效，请稍后重试。');
    }
    return RecoveryMailStatus(
      email,
      verified: result['verified'] == true,
      ready: result['ready'] == true,
    );
  }

  Future<Map<String, dynamic>> requestVerification(String expectedEmail) async {
    return api.request(
      'POST',
      '$path/verify',
      body: {'account_email': expectedEmail},
    );
  }

  Future<void> confirmVerification(String challenge, String code) async {
    final r = await api.request(
      'POST',
      '/api/accounting/v1/email-code/confirm',
      body: {'challenge': challenge, 'code': code},
    );
    if (r['verified'] != true) throw const CloudSyncException('邮箱验证未完成，请重试。');
  }

  Future<String> send({
    required LocalVault vault,
    required String recoveryCode,
    required String expectedEmail,
    required bool consent,
  }) async {
    if (!consent) throw const CloudSyncException('请先确认邮件备份的隐私说明。');
    final owner = api.ownerId;
    final recovered = await RecoveryCrypto.unwrap(
      vault.recoveryEnvelope,
      recoveryCode.trim(),
    );
    if (!constantTimeEqual(
      await recovered.extractBytes(),
      await vault.key.extractBytes(),
    )) {
      throw const SyncCryptoException('恢复码与本机密钥不匹配');
    }
    final current = await status();
    if (api.ownerId != owner || current.email != expectedEmail) {
      throw const CloudSyncException('登录账号或邮箱已变化，请重新核对收件人。');
    }
    if (!current.ready) throw const CloudSyncException('服务器尚未配置发信邮箱，请先完成邮件设置。');
    if (!current.verified) throw const CloudSyncException('请先验证登录邮箱，再发送恢复码。');
    try {
      final result = await api.request(
        'POST',
        path,
        body: {
          'vault_uid': vault.vaultUid,
          'recovery_code': recoveryCode.trim(),
          'account_email': expectedEmail,
          'consent': true,
        },
      );
      if (result['accepted'] != true || result['email'] != expectedEmail) {
        throw const CloudSyncException('未确认是否发送成功，请先检查收件箱和垃圾邮件，再决定是否重试。');
      }
      return expectedEmail;
    } on CloudSyncException catch (e) {
      if (e.status == null) {
        throw const CloudSyncException('未确认是否发送成功，请先检查收件箱和垃圾邮件，再决定是否重试。');
      }
      rethrow;
    }
  }
}
