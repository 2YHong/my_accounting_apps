import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

class SyncCryptoException implements Exception {
  final String message;
  const SyncCryptoException(this.message);
  @override
  String toString() => message;
}

List<int> secureSyncBytes(int length) {
  final random = Random.secure();
  return List.generate(length, (_) => random.nextInt(256));
}

String newSyncId() =>
    secureSyncBytes(16).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
bool constantTimeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Canonical metadata is authenticated to prevent substitution between records.
class RevisionContext {
  final String ownerId, vaultUid, objectUid, revisionUid;
  final List<String> parentUids;
  final int keyEpoch, formatVersion;
  RevisionContext({
    required this.ownerId,
    required this.vaultUid,
    required this.objectUid,
    required this.revisionUid,
    required List<String> parentUids,
    required this.keyEpoch,
    this.formatVersion = 1,
  }) : parentUids = List.unmodifiable(List<String>.of(parentUids)..sort()) {
    final id = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
    for (final value in [
      ownerId,
      vaultUid,
      objectUid,
      revisionUid,
      ...this.parentUids,
    ]) {
      if (!id.hasMatch(value)) throw const SyncCryptoException('加密记录标识无效');
    }
    if (keyEpoch < 1 ||
        keyEpoch > 9007199254740991 ||
        formatVersion != 1 ||
        this.parentUids.length > 64 ||
        this.parentUids.toSet().length != this.parentUids.length ||
        this.parentUids.contains(revisionUid)) {
      throw const SyncCryptoException('加密版本或父版本无效');
    }
  }
  List<int> get aad => utf8.encode(
    jsonEncode([
      'my_accounting_app.sync_revision',
      formatVersion,
      ownerId,
      vaultUid,
      objectUid,
      revisionUid,
      parentUids,
      keyEpoch,
      'AES-256-GCM',
    ]),
  );
}

class RevisionCrypto {
  static const maxPlaintextBytes = 192 * 1024;
  static const envelopeKeys = {
    'cipher_alg',
    'format_version',
    'key_epoch',
    'nonce',
    'ciphertext',
    'auth_tag',
  };
  final AesGcm _cipher = AesGcm.with256bits();
  Future<Map<String, Object>> encrypt(
    Map<String, Object?> payload, {
    required SecretKey key,
    required RevisionContext context,
  }) async {
    if ((await key.extractBytes()).length != 32) {
      throw const SyncCryptoException('加密密钥长度无效');
    }
    final plaintext = utf8.encode(jsonEncode(payload));
    if (plaintext.length > maxPlaintextBytes) {
      throw const SyncCryptoException('单条同步数据过大，请拆分后同步');
    }
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: secureSyncBytes(12),
      aad: context.aad,
    );
    return {
      'cipher_alg': 'AES-256-GCM',
      'format_version': context.formatVersion,
      'key_epoch': context.keyEpoch,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'auth_tag': base64Encode(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> decrypt(
    Map<String, dynamic> envelope, {
    required SecretKey key,
    required RevisionContext context,
  }) async {
    try {
      if (envelope.length != envelopeKeys.length ||
          envelope.keys.any((k) => !envelopeKeys.contains(k)) ||
          envelope['cipher_alg'] != 'AES-256-GCM' ||
          envelope['format_version'] != context.formatVersion ||
          envelope['key_epoch'] != context.keyEpoch) {
        throw const FormatException('Unsupported envelope');
      }
      List<int> bytes(String name, int maxCharacters) {
        final value = envelope[name];
        if (value is! String || value.length > maxCharacters) {
          throw const FormatException('Invalid envelope size');
        }
        final decoded = base64Decode(value);
        if (base64Encode(decoded) != value) {
          throw const FormatException('Non-canonical encoding');
        }
        return decoded;
      }

      final nonce = bytes('nonce', 16);
      final tag = bytes('auth_tag', 24);
      final ciphertext = bytes('ciphertext', 262144);
      if (nonce.length != 12 ||
          tag.length != 16 ||
          ciphertext.isEmpty ||
          ciphertext.length > maxPlaintextBytes ||
          (await key.extractBytes()).length != 32) {
        throw const FormatException('Invalid envelope');
      }
      final plaintext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
        aad: context.aad,
      );
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid payload');
      }
      return decoded;
    } catch (_) {
      throw const SyncCryptoException('无法解密：密钥不匹配或记录已被修改');
    }
  }
}

/// HKDF is appropriate here because recovery secrets have 256 bits of entropy.
/// Human passwords must never be substituted for these recovery codes.
class RecoveryCrypto {
  static const algorithm = 'HKDF-SHA256-AES-256-GCM';
  static const _keys = {
    'vault_uid',
    'recipient_uid',
    'key_epoch',
    'format_version',
    'wrap_alg',
    'salt',
    'nonce',
    'wrapped_key',
    'auth_tag',
  };
  static final _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static String _encode(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
  static Future<String> newCode() async {
    final secret = secureSyncBytes(32);
    final checksum = (await Sha256().hash(secret)).bytes.take(4).toList();
    return 'ACCT1.${_encode(secret)}.${_encode(checksum)}';
  }

  static Future<List<int>> _secret(String code) async {
    final parts = code.trim().split('.');
    if (parts.length != 3 ||
        parts[0] != 'ACCT1' ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(parts[1]) ||
        !RegExp(r'^[A-Za-z0-9_-]{6}$').hasMatch(parts[2])) {
      throw const SyncCryptoException('恢复码格式不正确');
    }
    try {
      final secret = base64Url.decode(base64Url.normalize(parts[1]));
      final checksum = (await Sha256().hash(secret)).bytes.take(4).toList();
      if (secret.length != 32 ||
          _encode(secret) != parts[1] ||
          _encode(checksum) != parts[2]) {
        throw const FormatException('Checksum mismatch');
      }
      return secret;
    } catch (_) {
      throw const SyncCryptoException('恢复码格式或校验码不正确');
    }
  }

  static List<int> _aad(String vault, String recipient, int epoch) =>
      utf8.encode(
        jsonEncode([
          'my_accounting_app.recovery_key',
          1,
          vault,
          recipient,
          epoch,
          algorithm,
        ]),
      );
  static Future<Map<String, Object>> wrap(
    SecretKey key, {
    required String code,
    required String vaultUid,
    required String recipientUid,
    int keyEpoch = 1,
  }) async {
    final secret = await _secret(code);
    if ((await key.extractBytes()).length != 32 || keyEpoch < 1) {
      throw const SyncCryptoException('密钥包参数无效');
    }
    final salt = secureSyncBytes(32);
    final aad = _aad(vaultUid, recipientUid, keyEpoch);
    final wrappingKey = await _kdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: salt,
      info: aad,
    );
    final box = await AesGcm.with256bits().encrypt(
      await key.extractBytes(),
      secretKey: wrappingKey,
      nonce: secureSyncBytes(12),
      aad: aad,
    );
    return {
      'vault_uid': vaultUid,
      'recipient_uid': recipientUid,
      'key_epoch': keyEpoch,
      'format_version': 1,
      'wrap_alg': algorithm,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'wrapped_key': base64Encode(box.cipherText),
      'auth_tag': base64Encode(box.mac.bytes),
    };
  }

  static Future<SecretKey> unwrap(
    Map<String, dynamic> envelope,
    String code,
  ) async {
    try {
      if (envelope.length != _keys.length ||
          envelope.keys.any((k) => !_keys.contains(k)) ||
          envelope['format_version'] != 1 ||
          envelope['wrap_alg'] != algorithm ||
          envelope['key_epoch'] is! int ||
          (envelope['key_epoch'] as int) < 1) {
        throw const FormatException('Unsupported envelope');
      }
      final id = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
      for (final name in ['vault_uid', 'recipient_uid']) {
        if (envelope[name] is! String ||
            !id.hasMatch(envelope[name] as String)) {
          throw const FormatException('Invalid identity');
        }
      }
      List<int> bytes(String name, int expected) {
        final value = envelope[name];
        if (value is! String || value.length > 128) {
          throw const FormatException('Invalid key envelope');
        }
        final data = base64Decode(value);
        if (data.length != expected || base64Encode(data) != value) {
          throw const FormatException('Invalid key material');
        }
        return data;
      }

      final salt = bytes('salt', 32);
      final nonce = bytes('nonce', 12);
      final wrapped = bytes('wrapped_key', 32);
      final tag = bytes('auth_tag', 16);
      final secret = await _secret(code);
      final aad = _aad(
        envelope['vault_uid'] as String,
        envelope['recipient_uid'] as String,
        envelope['key_epoch'] as int,
      );
      final wrappingKey = await _kdf.deriveKey(
        secretKey: SecretKey(secret),
        nonce: salt,
        info: aad,
      );
      final key = await AesGcm.with256bits().decrypt(
        SecretBox(wrapped, nonce: nonce, mac: Mac(tag)),
        secretKey: wrappingKey,
        aad: aad,
      );
      if (key.length != 32) {
        throw const FormatException('Invalid recovered key');
      }
      return SecretKey(key);
    } catch (_) {
      throw const SyncCryptoException('恢复码不匹配，或加密密钥包已损坏');
    }
  }
}
