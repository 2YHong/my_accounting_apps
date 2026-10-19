import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/sync/revision_crypto.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';

class MemorySecrets implements VaultSecretStorage {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('Secure storage unavailable');
    values[key] = value;
  }
}

RevisionContext context({
  String owner = 'owner_a',
  String object = 'object_a',
  List<String> parents = const ['parent_a'],
  int epoch = 1,
}) => RevisionContext(
  ownerId: owner,
  vaultUid: 'vault_a',
  objectUid: object,
  revisionUid: 'revision_a',
  parentUids: parents,
  keyEpoch: epoch,
);

void main() {
  final key = SecretKey(List.generate(32, (i) => i));
  final codec = RevisionCrypto();
  test(
    'round trip includes zero refunds, Unicode, deletes and generates fresh nonces',
    () async {
      final payload = <String, Object?>{
        'type': 'expense',
        'amount_cents': 0,
        'note': '午饭退款 🔐',
        'deleted': false,
        'parent': null,
      };
      final a = await codec.encrypt(payload, key: key, context: context());
      final b = await codec.encrypt(payload, key: key, context: context());
      expect(a['nonce'], isNot(b['nonce']));
      expect(jsonEncode(a), isNot(contains('午饭')));
      expect(await codec.decrypt(a, key: key, context: context()), payload);
      final tombstone = await codec.encrypt(
        {'deleted': true},
        key: key,
        context: context(),
      );
      expect(
        (await codec.decrypt(
          tombstone,
          key: key,
          context: context(),
        ))['deleted'],
        true,
      );
    },
  );
  test(
    'wrong key, substituted owner/object/parent/epoch and altered ciphertext fail',
    () async {
      final box = await codec.encrypt(
        {'amount': 2050},
        key: key,
        context: context(),
      );
      for (final ctx in [
        context(owner: 'owner_b'),
        context(object: 'object_b'),
        context(parents: ['other']),
        context(epoch: 2),
      ]) {
        await expectLater(
          codec.decrypt(box, key: key, context: ctx),
          throwsA(isA<SyncCryptoException>()),
        );
      }
      await expectLater(
        codec.decrypt(
          box,
          key: SecretKey(List.filled(32, 99)),
          context: context(),
        ),
        throwsA(isA<SyncCryptoException>()),
      );
      final damaged = Map<String, dynamic>.from(box);
      final bytes = base64Decode(damaged['ciphertext'] as String);
      bytes[0] ^= 1;
      damaged['ciphertext'] = base64Encode(bytes);
      await expectLater(
        codec.decrypt(damaged, key: key, context: context()),
        throwsA(isA<SyncCryptoException>()),
      );
    },
  );
  test(
    'canonical parent order decrypts but duplicate/self parents are rejected',
    () async {
      final a = context(parents: ['p2', 'p1']);
      final box = await codec.encrypt({'test': 1}, key: key, context: a);
      expect(
        await codec.decrypt(
          box,
          key: key,
          context: context(parents: ['p1', 'p2']),
        ),
        {'test': 1},
      );
      expect(
        () => context(parents: ['p1', 'p1']),
        throwsA(isA<SyncCryptoException>()),
      );
      expect(
        () => context(parents: ['revision_a']),
        throwsA(isA<SyncCryptoException>()),
      );
    },
  );
  test(
    'untrusted envelopes reject excess fields, malformed sizes and future format',
    () async {
      final box = await codec.encrypt(
        {'test': true},
        key: key,
        context: context(),
      );
      for (final patch in [
        {'nonce': 'AA=='},
        {'auth_tag': ''},
        {'ciphertext': 'A' * 262145},
        {'format_version': 2},
        {'extra': 'untrusted'},
      ]) {
        await expectLater(
          codec.decrypt({...box, ...patch}, key: key, context: context()),
          throwsA(isA<SyncCryptoException>()),
        );
      }
      await expectLater(
        codec.encrypt(
          {'huge': 'x' * (RevisionCrypto.maxPlaintextBytes + 1)},
          key: key,
          context: context(),
        ),
        throwsA(isA<SyncCryptoException>()),
      );
    },
  );
  test(
    'recovery unwraps root key; wrong valid recovery code and tampering fail',
    () async {
      final code = await RecoveryCrypto.newCode();
      final envelope = await RecoveryCrypto.wrap(
        key,
        code: code,
        vaultUid: 'vault_a',
        recipientUid: 'recovery_a',
      );
      expect(
        await (await RecoveryCrypto.unwrap(envelope, code)).extractBytes(),
        await key.extractBytes(),
      );
      expect(jsonEncode(envelope), isNot(contains(code)));
      await expectLater(
        RecoveryCrypto.unwrap(envelope, await RecoveryCrypto.newCode()),
        throwsA(isA<SyncCryptoException>()),
      );
      await expectLater(
        RecoveryCrypto.unwrap({...envelope, 'vault_uid': 'vault_b'}, code),
        throwsA(isA<SyncCryptoException>()),
      );
      await expectLater(
        RecoveryCrypto.unwrap({...envelope, 'wrap_alg': 'unknown'}, code),
        throwsA(isA<SyncCryptoException>()),
      );
      await expectLater(
        RecoveryCrypto.unwrap(envelope, 'short-password'),
        throwsA(isA<SyncCryptoException>()),
      );
    },
  );
  test(
    'keys require explicit commit, persist securely, and do not overwrite or cross user/scope',
    () async {
      final memory = MemorySecrets();
      final store = VaultKeyStore(storage: memory);
      final scope = 'a' * 32;
      final setup = await store.prepare();
      expect(memory.values, isEmpty);
      await store.commit(scope, 1, setup);
      final saved = await store.load(scope, 1);
      expect(saved, isNotNull);
      expect(await store.verifyRecovery(saved!, setup.recoveryCode), true);
      expect(memory.values.values.single, isNot(contains(setup.recoveryCode)));
      expect(await store.load(scope, 2), isNull);
      expect(await store.load('b' * 32, 1), isNull);
      await expectLater(
        store.commit(scope, 1, await store.prepare()),
        throwsA(isA<SyncCryptoException>()),
      );
      memory.values[memory.values.keys.single] = 'broken';
      await expectLater(
        store.load(scope, 1),
        throwsA(isA<SyncCryptoException>()),
      );
      await expectLater(
        store.commit(scope, 1, await store.prepare()),
        throwsA(isA<SyncCryptoException>()),
      );
    },
  );
  test('secure storage failure does not claim key setup succeeded', () async {
    final memory = MemorySecrets()..fail = true;
    final store = VaultKeyStore(storage: memory);
    await expectLater(
      store.commit('a' * 32, 1, await store.prepare()),
      throwsStateError,
    );
    expect(await store.load('a' * 32, 1), isNull);
  });
}
