import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/sync/pocketbase_api.dart';
import 'package:my_accounting_app/sync/vault_key_store.dart';

class MemorySecrets implements VaultSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test(
    'offline refresh preserves pinned identity; rejected refresh clears it',
    () async {
      final secrets = MemorySecrets();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      var status = 200;
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            status == 200
                ? {
                    'token': 'test-session',
                    'record': {'id': 'owner-a', 'email': 'a@example.invalid'},
                  }
                : {'message': 'test response'},
          ),
        );
        await request.response.close();
      });
      final first = PocketBaseApi(url: base, storage: secrets);
      await first.login('a@example.invalid', 'test-only');
      expect(first.accountEmail, 'a@example.invalid');
      status = 503;
      final resumed = PocketBaseApi(url: base, storage: secrets);
      await resumed.loadSession();
      expect(resumed.ownerId, 'owner-a');
      expect(resumed.accountEmail, 'a@example.invalid');
      status = 200;
      await resumed.loadSession();
      expect(resumed.ownerId, 'owner-a');
      status = 401;
      await expectLater(
        resumed.loadSession(),
        throwsA(isA<CloudSyncException>()),
      );
      expect(resumed.ownerId, isNull);
      final afterLogout = PocketBaseApi(url: base, storage: secrets);
      await afterLogout.loadSession();
      expect(afterLogout.ownerId, isNull);
    },
  );
  test(
    'registration requests verification without creating a logged-in session',
    () async {
      final secrets = MemorySecrets();
      final calls = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        calls.add(request.uri.path);
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['email'], 'pending@example.invalid');
        request.response.statusCode = 200;
        request.response.write(jsonEncode({'challenge': 'a' * 40}));
        await request.response.close();
      });
      final api = PocketBaseApi(
        url: 'http://127.0.0.1:' + server.port.toString(),
        storage: secrets,
      );
      await api.registerForVerification('pending@example.invalid', 'test-only');
      expect(calls, ['/api/accounting/v1/email-code/request']);
      expect(api.ownerId, isNull);
      expect(secrets.values, isEmpty);
    },
  );
}
