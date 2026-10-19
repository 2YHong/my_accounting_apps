import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/recovery_mail_sender.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';

class MailSecrets implements VaultSecretStorage {
  @override Future<String?> read(String key) async => null;
  @override Future<void> write(String key, String value) async {}
}
class MailApi implements SyncTransport {
  @override String? ownerId = 'owner';
  String email = 'owner@example.invalid';
  bool verified = true, ready = true;
  int posts = 0, reads = 0;
  Map<String,dynamic>? last;
  @override Future<Map<String,dynamic>> request(String method, String path,
      {Map<String,dynamic>? body, Map<String,String>? query}) async {
    if (method == 'GET') { reads++; return {'protocol':1,'email':email,'verified':verified,'ready':ready}; }
    posts++; last = body;
    return {'accepted':true,'email':email};
  }
}
void main() {
  late VaultSetup setup;
  setUp(() async { setup = await VaultKeyStore(storage:MailSecrets()).prepare(); });
  test('explicit mail sends only after local cryptographic validation and account verification', () async {
    final api = MailApi(), sender = RecoveryMailSender(MailApi());
    final service = RecoveryMailSender(api);
    expect((await sender.status()).verified,isTrue);
    await service.send(vault:setup.vault,recoveryCode:setup.recoveryCode,
      expectedEmail:api.email,consent:true);
    expect(api.posts,1);
    expect(api.last!['account_email'],api.email);
    expect(api.last!['recovery_code'],setup.recoveryCode);
    expect(api.last!.keys,unorderedEquals(['vault_uid','account_email','recovery_code','consent']));
  });
  test('wrong code and missing consent never make a network call', () async {
    final api = MailApi(), other = await VaultKeyStore(storage:MailSecrets()).prepare();
    final service = RecoveryMailSender(api);
    await expectLater(service.send(vault:setup.vault,recoveryCode:other.recoveryCode,
      expectedEmail:api.email,consent:true),throwsA(isA<Exception>()));
    await expectLater(service.send(vault:setup.vault,recoveryCode:setup.recoveryCode,
      expectedEmail:api.email,consent:false),throwsA(isA<CloudSyncException>()));
    expect(api.posts,0); expect(api.reads,0);
  });
  test('unverified, unconfigured and changed account never receive a code', () async {
    final api=MailApi(), service=RecoveryMailSender(MailApi());
    expect((await service.status()).ready,isTrue);
    final sender=RecoveryMailSender(api);
    for (final state in [0,1,2]) {
      api.verified=state!=0; api.ready=state!=1;
      await expectLater(sender.send(vault:setup.vault,recoveryCode:setup.recoveryCode,
        expectedEmail:state==2?'changed@example.invalid':api.email,consent:true),
        throwsA(isA<CloudSyncException>()));
    }
    expect(api.posts,0);
  });
  test('logged out user cannot query mail settings or send recovery code', () async {
    final api=MailApi()..ownerId=null;
    await expectLater(RecoveryMailSender(api).status(),throwsA(isA<CloudSyncException>()));
    expect(api.reads,0); expect(api.posts,0);
  });
}
