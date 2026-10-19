import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/widgets/email_code_dialog.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';

void main() {
  testWidgets(
    'six digits required; confirmed challenge closes without password storage',
    (tester) async {
      var requests = 0, confirmed = 0;
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) => EmailCodeDialog(
                    email: 'test@example.invalid',
                    request: () async {
                      requests++;
                      return {'challenge': 'a' * 40};
                    },
                    confirm: (challenge, code) async {
                      expect(challenge, 'a' * 40);
                      expect(code, '123456');
                      confirmed++;
                    },
                  ),
                );
              },
              child: const Text('注册'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('注册'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('填写邮箱验证码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '12345');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      expect(confirmed, 1);
      expect(result, true);
    },
  );
  testWidgets('incorrect code stays open and resend waits one minute', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EmailCodeDialog(
          email: 'x@example.invalid',
          request: () async {
            requests++;
            return {'challenge': 'b' * 40};
          },
          confirm: (_, _) async {
            throw const CloudSyncException('验证码不正确');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '000000');
    await tester.pump();
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(find.text('验证码不正确'), findsOneWidget);
    expect(requests, 1);
    expect(find.textContaining('重新发送（'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    await tester.tap(find.text('重新发送验证码'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
