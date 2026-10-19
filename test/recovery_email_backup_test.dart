import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/recovery_email_backup.dart';
import 'package:my_accounting_app/sync/revision_crypto.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';

void main() {
  late VaultSetup setup;
  setUp(() async {
    setup = await VaultKeyStore().prepare();
  });

  test(
    'draft contains verified recovery code and correctly encoded Chinese text',
    () async {
      final uri = await const RecoveryEmailBackup().draft(
        vault: setup.vault,
        recoveryCode: setup.recoveryCode,
        recipient: 'me+backup@example.com',
        accountEmail: 'account@example.com',
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'me+backup@example.com');
      expect(uri.queryParameters['subject'], '我的记账本：恢复码备份');
      final body = uri.queryParameters['body']!;
      expect(body, contains(setup.recoveryCode));
      expect(body, contains('account@example.com'));
      expect(body, contains('完整备份文件的密码'));
      expect(uri.query, isNot(contains('+')));
    },
  );

  test('opening a draft only calls the local launcher once', () async {
    var calls = 0;
    final service = RecoveryEmailBackup(
      launcher: (uri) async {
        calls++;
        expect(uri.scheme, 'mailto');
        return true;
      },
    );
    expect(
      await service.openDraft(
        vault: setup.vault,
        recoveryCode: setup.recoveryCode,
        recipient: 'me@example.com',
      ),
      isTrue,
    );
    expect(calls, 1);
  });

  test('wrong recovery code never reaches a mail application', () async {
    var launched = false;
    final service = RecoveryEmailBackup(
      launcher: (_) async {
        launched = true;
        return true;
      },
    );
    final wrong = await RecoveryCrypto.newCode();
    await expectLater(
      service.openDraft(
        vault: setup.vault,
        recoveryCode: wrong,
        recipient: 'me@example.com',
      ),
      throwsA(isA<SyncCryptoException>()),
    );
    expect(launched, isFalse);
  });

  test('invalid or multiple recipients are rejected', () async {
    for (final email in [
      '',
      'invalid',
      'a@example.com,b@example.com',
      'a@example.com\nBcc:other@example.com',
      'a@example.com;other@example.com',
    ]) {
      expect(RecoveryEmailBackup.validRecipient(email), isFalse);
      await expectLater(
        const RecoveryEmailBackup().draft(
          vault: setup.vault,
          recoveryCode: setup.recoveryCode,
          recipient: email,
        ),
        throwsA(isA<SyncCryptoException>()),
      );
    }
  });

  test(
    'missing mail app or platform errors return failure without exposing secret URLs',
    () async {
      for (final service in [
        RecoveryEmailBackup(launcher: (_) async => false),
        RecoveryEmailBackup(
          launcher: (uri) async => throw StateError(uri.toString()),
        ),
      ]) {
        expect(
          await service.openDraft(
            vault: setup.vault,
            recoveryCode: setup.recoveryCode,
            recipient: 'me@example.com',
          ),
          isFalse,
        );
      }
    },
  );
}
