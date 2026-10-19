import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../models/full_backup.dart';

/// Password-protected, authenticated, versioned archive. Call this CPU-intensive
/// codec in a worker isolate; the service below supplies that wrapper.
class BackupCodec {
  static const maxEncryptedBytes = 96 * 1024 * 1024;
  static const maxPlaintextBytes = 64 * 1024 * 1024;
  static const iterations = 600000;
  static const _format = 'my_accounting_app.encrypted_backup';
  static const _keys = {'format','version','algorithm','kdf','iterations','salt','nonce','ciphertext','mac'};
  static final _aad = utf8.encode('$_format|1|AES-256-GCM|PBKDF2-HMAC-SHA256|$iterations');

  static void validatePassword(String password) {
    final length = password.runes.length;
    if (length < 8 || length > 128) throw const FullBackupException('密码需要 8 至 128 个字符');
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
  static Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
      .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Uint8List> encrypt(Map<String,Object?> snapshot, String password) async {
    validatePassword(password);
    final plaintext = utf8.encode(jsonEncode(snapshot));
    if (plaintext.length > maxPlaintextBytes) throw const FullBackupException('备份数据超过 64 MB，暂不支持导出');
    final salt = _randomBytes(16); final nonce = _randomBytes(12);
    final secretKey = await _key(password,salt);
    final box = await AesGcm.with256bits().encrypt(plaintext,secretKey:secretKey,nonce:nonce,aad:_aad);
    return Uint8List.fromList(utf8.encode(jsonEncode({'format':_format,'version':1,
      'algorithm':'AES-256-GCM','kdf':'PBKDF2-HMAC-SHA256','iterations':iterations,
      'salt':base64Encode(salt),'nonce':base64Encode(nonce),
      'ciphertext':base64Encode(box.cipherText),'mac':base64Encode(box.mac.bytes)})));
  }

  static Future<Map<String,dynamic>> decrypt(Uint8List bytes, String password) async {
    validatePassword(password);
    if (bytes.isEmpty || bytes.length > maxEncryptedBytes) throw const FullBackupException('备份文件为空或超过 96 MB');
    try {
      final envelope = jsonDecode(utf8.decode(bytes));
      if (envelope is! Map<String,dynamic> || envelope.length != _keys.length ||
        envelope.keys.any((key) => !_keys.contains(key)) || envelope['format'] != _format ||
        envelope['version'] != 1 || envelope['algorithm'] != 'AES-256-GCM' ||
        envelope['kdf'] != 'PBKDF2-HMAC-SHA256' || envelope['iterations'] != iterations) {
        throw const FullBackupException('备份格式不正确或版本不受支持');
      }
      for (final key in ['salt','nonce','ciphertext','mac']) {
        if (envelope[key] is! String) throw const FormatException('Invalid encoding');
      }
      final salt = base64Decode(envelope['salt'] as String);
      final nonce = base64Decode(envelope['nonce'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      if (salt.length != 16 || nonce.length != 12 || mac.length != 16 ||
        ciphertext.isEmpty || ciphertext.length > maxPlaintextBytes) throw const FormatException('Invalid lengths');
      final secretKey = await _key(password,salt);
      final plaintext = await AesGcm.with256bits().decrypt(
        SecretBox(ciphertext,nonce:nonce,mac:Mac(mac)),secretKey:secretKey,aad:_aad);
      final snapshot = jsonDecode(utf8.decode(plaintext));
      if (snapshot is! Map<String,dynamic>) throw const FormatException('Invalid payload');
      return snapshot;
    } on FullBackupException { rethrow; }
    catch (_) { throw const FullBackupException('密码不正确，或备份文件已损坏'); }
  }
}

Future<Uint8List> encryptBackupWorker(Map<String,Object?> args) =>
  BackupCodec.encrypt(Map<String,Object?>.from(args['snapshot'] as Map),args['password'] as String);
Future<Map<String,dynamic>> decryptBackupWorker(Map<String,Object?> args) =>
  BackupCodec.decrypt(args['bytes'] as Uint8List,args['password'] as String);
