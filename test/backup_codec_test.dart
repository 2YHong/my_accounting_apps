import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/models/full_backup.dart';
import 'package:my_accounting_app/services/backup_codec.dart';

void main() {
  const password = '家庭备份密码 2026';
  final snapshot = <String,Object?>{'name':'牛奶','amount':7.0,
    'settings':{'dark_mode':true},'private_note':'银行账户余额'};
  late Uint8List encrypted;
  setUpAll(() async { encrypted = await BackupCodec.encrypt(snapshot,password); });

  test('加密备份完整往返，文件不含账单明文',() async {
    final text = utf8.decode(encrypted);
    expect(text, isNot(contains('牛奶')));
    expect(text, isNot(contains('银行账户余额')));
    expect(await BackupCodec.decrypt(encrypted,password),snapshot);
  });
  test('错误密码拒绝恢复',() async {
    await expectLater(BackupCodec.decrypt(encrypted,'另一组错误密码'),
      throwsA(isA<FullBackupException>()));
  });
  test('密文或认证标签被修改时拒绝恢复',() async {
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String,dynamic>;
    final mac = base64Decode(envelope['mac'] as String);
    mac[0] ^= 1;
    envelope['mac'] = base64Encode(mac);
    await expectLater(BackupCodec.decrypt(Uint8List.fromList(utf8.encode(jsonEncode(envelope))),password),
      throwsA(isA<FullBackupException>()));
  });
  test('重复加密同一份数据使用不同盐和随机数',() async {
    final second = await BackupCodec.encrypt(snapshot,password);
    final firstEnvelope = jsonDecode(utf8.decode(encrypted)) as Map;
    final secondEnvelope = jsonDecode(utf8.decode(second)) as Map;
    expect(secondEnvelope['salt'],isNot(firstEnvelope['salt']));
    expect(secondEnvelope['nonce'],isNot(firstEnvelope['nonce']));
    expect(await BackupCodec.decrypt(second,password),snapshot);
  });
  test('算法、KDF次数和文件版本必须精确匹配',() async {
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String,dynamic>;
    envelope['iterations'] = 1;
    await expectLater(BackupCodec.decrypt(Uint8List.fromList(utf8.encode(jsonEncode(envelope))),password),
      throwsA(isA<FullBackupException>()));
  });
  test('密码长度按字符检查且不会移除首尾空格',() async {
    expect(() => BackupCodec.validatePassword('短密码'),throwsA(isA<FullBackupException>()));
    expect(() => BackupCodec.validatePassword(List.filled(129,'a').join()),throwsA(isA<FullBackupException>()));
    expect(() => BackupCodec.validatePassword(' 123456 '),returnsNormally);
  });
}
