import 'package:my_accounting_app/services/recovery_email_backup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/pages/sync_security_page.dart';
import 'package:my_accounting_app/sync/local_sync_repository.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';

class PageSecrets implements VaultSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class PageRepository extends LocalSyncRepository {
  @override
  Future<LocalSyncStatus> status() async => LocalSyncStatus('a' * 32, 1, 3);
}

/// Crypto/storage correctness is tested separately. Here isolate confirmation UI.
class PageKeys extends VaultKeyStore {
  final VaultSetup setup;
  LocalVault? saved;
  PageKeys(this.setup, VaultSecretStorage storage) : super(storage: storage);
  @override
  Future<VaultSetup> prepare() async => setup;
  @override
  Future<LocalVault?> load(String scope, int userId) async => saved;
  @override
  Future<void> commit(String scope, int userId, VaultSetup value) async {
    await storage.write('test-confirmation', 'saved');
    saved = value.vault;
  }
}

class FakeRecoveryEmail extends RecoveryEmailBackup {
  final bool opens;
  int calls = 0;
  String? code;
  FakeRecoveryEmail({this.opens = true});
  @override
  Future<bool> openDraft({
    required LocalVault vault,
    required String recoveryCode,
    required String recipient,
    String? accountEmail,
  }) async {
    calls++;
    code = recoveryCode;
    return opens;
  }
}

void main() {
  testWidgets('opening or cancelling recovery setup never persists a key', (
    tester,
  ) async {
    final storage = PageSecrets();
    final setup = (await tester.runAsync(
      () => VaultKeyStore(storage: storage).prepare(),
    ))!;
    final keys = PageKeys(setup, storage);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncSecurityPage(repository: PageRepository(), keyStore: keys),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('3 个对象'), findsOneWidget);
    expect(storage.values, isEmpty);
    await tester.tap(find.text('生成本机密钥与恢复码'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('保存恢复码'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并保存密钥'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(storage.values, isEmpty);
  });
  testWidgets(
    'explicit recovery confirmation commits once and enables local self-test',
    (tester) async {
      final storage = PageSecrets();
      final setup = (await tester.runAsync(
        () => VaultKeyStore(storage: storage).prepare(),
      ))!;
      final keys = PageKeys(setup, storage);
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSecurityPage(repository: PageRepository(), keyStore: keys),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成本机密钥与恢复码'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('我已保存恢复码'));
      await tester.tap(find.text('我已保存恢复码'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('确认并保存密钥'));
      await tester.pumpAndSettle();
      expect(storage.values.length, 1);
      expect(find.text('已保存在系统安全存储'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '本机加密自检'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'email backup during creation opens a draft without confirming key storage',
    (tester) async {
      final storage = PageSecrets();
      final setup = (await tester.runAsync(
        () => VaultKeyStore(storage: storage).prepare(),
      ))!;
      final keys = PageKeys(setup, storage);
      final email = FakeRecoveryEmail();
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSecurityPage(
            repository: PageRepository(),
            keyStore: keys,
            emailBackup: email,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('生成本机密钥与恢复码'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('备份到邮箱'));
      await tester.tap(find.text('备份到邮箱'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('使用本机邮箱草稿'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextFormField), 'me@example.com');
      await tester.tap(find.text('打开邮箱草稿'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(email.calls, 1);
      expect(email.code, setup.recoveryCode);
      expect(storage.values, isEmpty);
      expect(find.text('保存恢复码'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并保存密钥'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'existing key email backup requires the original recovery code and handles missing mail apps',
    (tester) async {
      final storage = PageSecrets();
      final setup = (await tester.runAsync(
        () => VaultKeyStore(storage: storage).prepare(),
      ))!;
      final keys = PageKeys(setup, storage)..saved = setup.vault;
      final email = FakeRecoveryEmail(opens: false);
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSecurityPage(
            repository: PageRepository(),
            keyStore: keys,
            emailBackup: email,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('备份恢复码到邮箱'));
      await tester.tap(find.text('备份恢复码到邮箱'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('输入已有恢复码以备份'), findsOneWidget);
      await tester.enterText(find.byType(TextField), setup.recoveryCode);
      await tester.tap(find.text('校验'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('使用本机邮箱草稿'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextFormField), 'me@example.com');
      await tester.tap(find.text('打开邮箱草稿'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(email.calls, 1);
      expect(find.textContaining('无法打开邮箱应用'), findsOneWidget);
      expect(storage.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
