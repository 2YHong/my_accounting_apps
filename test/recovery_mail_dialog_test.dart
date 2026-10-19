import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/recovery_mail_sender.dart';
import 'package:my_accounting_app/widgets/recovery_mail_dialog.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';
import 'recovery_mail_sender_test.dart' show MailApi, MailSecrets;

class DialogSender extends RecoveryMailSender {
  bool verified;
  int verifications = 0, sends = 0;
  DialogSender({this.verified = true}) : super(MailApi());
  @override
  Future<RecoveryMailStatus> status() async => RecoveryMailStatus(
    'owner@example.invalid',
    verified: verified,
    ready: true,
  );
  @override
  Future<Map<String, dynamic>> requestVerification(String email) async {
    verifications++;
    return {'challenge': 'a' * 40};
  }

  @override
  Future<void> confirmVerification(String challenge, String code) async {
    if (code != '123456') throw const CloudSyncException('Wrong code');
    verified = true;
  }

  @override
  Future<String> send({
    required LocalVault vault,
    required String recoveryCode,
    required String expectedEmail,
    required bool consent,
  }) async {
    if (!consent) throw const CloudSyncException('No consent');
    sends++;
    return expectedEmail;
  }
}

void main() {
  testWidgets(
    'verified account sends without repeated email verification; privacy opt-in is required',
    (tester) async {
      final setup = (await tester.runAsync(
        () => VaultKeyStore(storage: MailSecrets()).prepare(),
      ))!;
      final sender = DialogSender();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecoveryMailDialog(
              sender: sender,
              vault: setup.vault,
              recoveryCode: setup.recoveryCode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('填写邮箱验证码'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送恢复码'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('发送恢复码'));
      await tester.pumpAndSettle();
      expect(sender.verifications, 0);
      expect(sender.sends, 1);
      expect(find.textContaining('发信服务接受'), findsOneWidget);
      expect(find.text('发送恢复码'), findsNothing);
    },
  );
  testWidgets(
    'old unverified account verifies once then refreshes to enable mail',
    (tester) async {
      final setup = (await tester.runAsync(
        () => VaultKeyStore(storage: MailSecrets()).prepare(),
      ))!;
      final sender = DialogSender(verified: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecoveryMailDialog(
              sender: sender,
              vault: setup.vault,
              recoveryCode: setup.recoveryCode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发送恢复码'), findsNothing);
      await tester.tap(find.text('填写邮箱验证码'));
      await tester.pumpAndSettle();
      expect(sender.verifications, 1);
      expect(sender.sends, 0);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      expect(find.text('填写邮箱验证码'), findsNothing);
      expect(find.text('发送恢复码'), findsOneWidget);
    },
  );
}
