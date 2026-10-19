import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'revision_crypto.dart';

abstract interface class VaultSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PlatformVaultSecretStorage implements VaultSecretStorage {
  final FlutterSecureStorage storage;
  const PlatformVaultSecretStorage({
    this.storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    ),
  });
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
}

class LocalVault {
  final String vaultUid, deviceUid;
  final SecretKey key;
  final Map<String, dynamic> recoveryEnvelope;
  LocalVault({
    required this.vaultUid,
    required this.deviceUid,
    required this.key,
    required Map<String, dynamic> recoveryEnvelope,
  }) : recoveryEnvelope = Map.unmodifiable(recoveryEnvelope);
}

class VaultSetup {
  final LocalVault vault;
  final String recoveryCode;
  VaultSetup(this.vault, this.recoveryCode);
}

/// One secure-storage entry per local user AND database installation scope.
/// A full restore rotates the scope so restored numeric IDs cannot inherit keys.
class VaultKeyStore {
  final VaultSecretStorage storage;
  VaultKeyStore({this.storage = const PlatformVaultSecretStorage()});
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  String _slot(String scope, int userId) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(scope) || userId <= 0) {
      throw const SyncCryptoException('本地用户或数据库标识无效');
    }
    return 'accounting.e2ee.v1.$scope.$userId';
  }

  Future<LocalVault?> load(String scope, int userId) async {
    final encoded = await storage.read(_slot(scope, userId));
    if (encoded == null) return null;
    try {
      if (encoded.length > 8192) throw const FormatException('Invalid vault');
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      if (data.length != 7 ||
          data['format'] != 'accounting.local_vault' ||
          data['version'] != 1 ||
          data['scope'] != scope ||
          data['user_id'] != userId ||
          data['key_epoch'] != 1) {
        throw const FormatException('Scope mismatch');
      }
      final value = data['vault'] as Map<String, dynamic>;
      if (value.length != 4) throw const FormatException('Invalid vault');
      final id = RegExp(r'^[a-f0-9]{32}$');
      final vault = value['vault_uid'] as String;
      final device = value['device_uid'] as String;
      final bytes = base64Decode(value['key'] as String);
      final recovery = Map<String, dynamic>.from(value['recovery'] as Map);
      if (!id.hasMatch(vault) ||
          !id.hasMatch(device) ||
          bytes.length != 32 ||
          recovery['vault_uid'] != vault ||
          recovery['key_epoch'] != 1 ||
          data['recovery_confirmed'] != true) {
        throw const FormatException('Invalid vault material');
      }
      return LocalVault(
        vaultUid: vault,
        deviceUid: device,
        key: SecretKey(bytes),
        recoveryEnvelope: recovery,
      );
    } catch (_) {
      throw const SyncCryptoException('本机加密配置损坏，不能自动生成新密钥覆盖它');
    }
  }

  /// Nothing is stored until the user confirms possession of the recovery code.
  Future<VaultSetup> prepare() async {
    final key = SecretKey(secureSyncBytes(32));
    final vault = newSyncId(), device = newSyncId();
    final code = await RecoveryCrypto.newCode();
    final envelope = await RecoveryCrypto.wrap(
      key,
      code: code,
      vaultUid: vault,
      recipientUid: newSyncId(),
    );
    return VaultSetup(
      LocalVault(
        vaultUid: vault,
        deviceUid: device,
        key: key,
        recoveryEnvelope: envelope,
      ),
      code,
    );
  }

  Future<void> commit(String scope, int userId, VaultSetup setup) =>
      _serial(() async {
        final slot = _slot(scope, userId);
        if (await storage.read(slot) != null) {
          throw const SyncCryptoException('此用户已有密钥，已阻止覆盖');
        }
        final recovered = await RecoveryCrypto.unwrap(
          setup.vault.recoveryEnvelope,
          setup.recoveryCode,
        );
        if (!constantTimeEqual(
          await recovered.extractBytes(),
          await setup.vault.key.extractBytes(),
        )) {
          throw const SyncCryptoException('恢复码校验失败，密钥没有保存');
        }
        final encoded = jsonEncode({
          'format': 'accounting.local_vault',
          'version': 1,
          'scope': scope,
          'user_id': userId,
          'recovery_confirmed': true,
          'vault': {
            'vault_uid': setup.vault.vaultUid,
            'device_uid': setup.vault.deviceUid,
            'key': base64Encode(await setup.vault.key.extractBytes()),
            'recovery': setup.vault.recoveryEnvelope,
          },
          'key_epoch': 1,
        });
        await storage.write(slot, encoded);
        final saved = await load(scope, userId);
        if (saved == null ||
            !constantTimeEqual(
              await saved.key.extractBytes(),
              await setup.vault.key.extractBytes(),
            )) {
          throw const SyncCryptoException('安全存储校验失败，请保留恢复码并重新打开页面');
        }
      });
  Future<bool> verifyRecovery(LocalVault vault, String code) async {
    final recovered = await RecoveryCrypto.unwrap(vault.recoveryEnvelope, code);
    return constantTimeEqual(
      await recovered.extractBytes(),
      await vault.key.extractBytes(),
    );
  }
}
