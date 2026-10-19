import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'vault_key_store.dart';
import 'revision_crypto.dart';

class CloudSyncException implements Exception {
  final String message;
  final int? status;
  const CloudSyncException(this.message, [this.status]);
  @override
  String toString() => message;
}

abstract interface class SyncTransport {
  String? get ownerId;
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  });
}

class PocketBaseApi implements SyncTransport {
  final Uri base;
  final VaultSecretStorage storage;
  final HttpClient _client;
  String? _token, _ownerId, _email;
  bool? emailVerified;
  String? get accountEmail => _email;
  @override
  String? get ownerId => _ownerId;
  PocketBaseApi({
    String url = 'https://api.698239.xyz',
    this.storage = const PlatformVaultSecretStorage(),
    HttpClient? client,
  }) : base = Uri.parse(url),
       _client = client ?? HttpClient() {
    if (base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty ||
        !['', '/'].contains(base.path) ||
        (base.scheme != 'https' &&
            !(base.scheme == 'http' &&
                ['127.0.0.1', 'localhost'].contains(base.host)))) {
      throw const CloudSyncException('云服务地址必须使用 HTTPS');
    }
    _client.connectionTimeout = const Duration(seconds: 15);
  }
  String get _slot => 'accounting.pb.auth.${base.origin}';
  Future<void> loadSession() async {
    final raw = await storage.read(_slot);
    if (raw == null) return;
    try {
      final session = jsonDecode(raw) as Map<String, dynamic>;
      _token = session['token'] as String;
      _ownerId = session['owner'] as String;
      _email = session['email'] as String?;
      if (_token!.isEmpty || _ownerId!.isEmpty) {
        throw const FormatException('Empty session');
      }
    } catch (_) {
      await logout();
      return;
    }
    try {
      final refreshed = await request(
        'POST',
        '/api/collections/users/auth-refresh',
      );
      final record = refreshed['record'];
      if (record is! Map ||
          record['id'] != _ownerId ||
          refreshed['token'] is! String) {
        await logout();
        throw const CloudSyncException('登录刷新响应不一致');
      }
      _token = refreshed['token'] as String;
      _email = record['email'] as String?;
      emailVerified = record['verified'] == true;
      await storage.write(
        _slot,
        jsonEncode({'token': _token, 'owner': _ownerId, 'email': _email}),
      );
    } on CloudSyncException catch (e) {
      if ([400, 401, 403].contains(e.status)) {
        await logout();
        rethrow;
      }
      // Keep the pinned cached identity while offline; it grants no new access.
      // Temporary network and server failures retain the pinned session.
    }
  }

  Future<void> login(String email, String password) async {
    _token = null;
    _ownerId = null;
    final result = await request(
      'POST',
      '/api/collections/users/auth-with-password',
      body: {'identity': email.trim(), 'password': password},
    );
    final record = result['record'] as Map;
    final owner = record['id'];
    _email = record['email'] as String?;
    emailVerified = record['verified'] == true;
    if (owner is! String || result['token'] is! String) {
      throw const CloudSyncException('登录响应无效');
    }
    await storage.write(
      _slot,
      jsonEncode({'token': result['token'], 'owner': owner, 'email': _email}),
    );
    _token = result['token'] as String;
    _ownerId = owner;
  }

  Future<void> register(String email, String password) async {
    await request(
      'POST',
      '/api/collections/users/records',
      body: {
        'email': email.trim(),
        'password': password,
        'passwordConfirm': password,
      },
    );
    await login(email, password);
  }

  Future<Map<String, dynamic>> registerForVerification(
    String email,
    String password,
  ) => request(
    'POST',
    '/api/accounting/v1/email-code/request',
    body: {'email': email.trim(), 'password': password},
  );

  Future<Map<String, dynamic>> requestOwnEmailCode() => request(
    'POST',
    '/api/accounting/v1/recovery-mail/verify',
    body: {'account_email': accountEmail},
  );

  Future<void> confirmEmailCode(String challenge, String code) async {
    final r = await request(
      'POST',
      '/api/accounting/v1/email-code/confirm',
      body: {'challenge': challenge, 'code': code},
    );
    if (r['verified'] != true) throw const CloudSyncException('邮箱验证未完成，请重试。');
  }

  Future<void> logout() async {
    _token = null;
    _ownerId = null;
    _email = null;
    emailVerified = null;
    // Empty entry invalidates the local session without a server-side logout claim.
    await storage.write(_slot, '{}');
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    try {
      final uri = base.resolve(path).replace(queryParameters: query);
      final req = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      if (_token != null) req.headers.set('Authorization', _token!);
      if (body != null) req.write(jsonEncode(body));
      final response = await req.close().timeout(const Duration(seconds: 30));
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 10 * 1024 * 1024) {
          throw const CloudSyncException('同步响应过大，已停止接收');
        }
      }
      final decoded = bytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(bytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final rawReason = decoded is Map ? decoded['message'] : null;
        final mailReason = rawReason is String
            ? rawReason.toLowerCase().replaceFirst(RegExp(r'\.$'), '')
            : null;
        const mailMessages = {
          'not_configured': '服务器尚未配置发信邮箱，请先完成邮件设置。',
          'unverified': '请先验证登录邮箱，再发送恢复码。',
          'email_changed': '登录邮箱已变化，请重新打开邮件备份。',
          'vault_changed': '此恢复码对应的加密空间与云端不一致，已停止发送。',
          'consent_required': '请先确认邮件备份的隐私说明。',
          'rate_limited': '发送过于频繁，请至少等一分钟后重试；每天最多发送五次。',
          'send_failed': '发信服务未确认接收，请先检查邮箱和垃圾邮件，再决定是否重试。',
          'invalid': '请求未通过校验，请核对后重试。',
          'invalid_credentials': '邮箱或密码未通过校验。新密码至少 8 位；已注册的邮箱请填写原密码。',
          'already_verified': '此邮箱已经验证，请使用原密码直接登录。',
          'invalid_code': '验证码不正确或已失效，请核对最新邮件；连续错误 5 次后需重新发送。',
          'code_expired': '验证码已过期或错误次数已达上限，请重新发送。',
        };
        if ((path.startsWith('/api/accounting/v1/recovery-mail') ||
                path.startsWith('/api/accounting/v1/email-code')) &&
            mailMessages.containsKey(mailReason)) {
          throw CloudSyncException(
            mailMessages[mailReason]!,
            response.statusCode,
          );
        }
        final message = switch (response.statusCode) {
          400 =>
            path.contains('auth-with-password')
                ? '邮箱或密码不正确，或邮箱尚未验证；新账号请先填写邮箱验证码完成验证。'
                : '提交内容未通过校验，请检查邮箱、密码或服务器设置',
          401 => '登录已失效，请重新登录',
          403 =>
            path.contains('auth-with-password')
                ? '邮箱尚未验证或账号权限受限，请先完成邮箱验证。'
                : '当前设备没有同步权限',
          404 => '同步接口尚未部署，或目标不存在',
          409 =>
            decoded is Map && decoded['message'] is String
                ? decoded['message'] as String
                : '同步状态冲突，请刷新后重试',
          429 => '请求过于频繁，请稍后重试',
          _ => '云端操作失败，请检查服务器状态',
        };
        throw CloudSyncException(message, response.statusCode);
      }
      if (decoded is! Map<String, dynamic>) {
        throw const CloudSyncException('同步响应格式错误');
      }
      return decoded;
    } on CloudSyncException {
      rethrow;
    } on TimeoutException {
      throw const CloudSyncException('连接超时，本机修改已保留，可稍后重试');
    } catch (_) {
      throw const CloudSyncException('网络连接或响应校验失败，本机数据已保留');
    }
  }
}

class CloudVaultKeys {
  final VaultSecretStorage storage;
  CloudVaultKeys({this.storage = const PlatformVaultSecretStorage()});
  String _slot(String scope, int user, String owner, String vault) =>
      'accounting.pb.keys.$scope.$user.$owner.$vault';
  Future<LocalVault?> load(
    String scope,
    int user,
    String owner,
    String vault,
  ) async {
    final raw = await storage.read(_slot(scope, user, owner, vault));
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['owner'] != owner ||
          data['scope'] != scope ||
          data['user'] != user ||
          data['vault_uid'] != vault) {
        throw const FormatException();
      }
      final bytes = base64Decode(data['key'] as String);
      if (bytes.length != 32) throw const FormatException();
      return LocalVault(
        vaultUid: vault,
        deviceUid: data['device_uid'] as String,
        key: SecretKey(bytes),
        recoveryEnvelope: Map<String, dynamic>.from(data['recovery'] as Map),
      );
    } catch (_) {
      throw const CloudSyncException('本机云密钥配置损坏，请保留恢复码，不要覆盖配置');
    }
  }

  Future<void> save(
    String scope,
    int user,
    String owner,
    LocalVault vault,
  ) async {
    final slot = _slot(scope, user, owner, vault.vaultUid);
    final old = await load(scope, user, owner, vault.vaultUid);
    if (old != null &&
        !constantTimeEqual(
          await old.key.extractBytes(),
          await vault.key.extractBytes(),
        )) {
      throw const CloudSyncException('已有云密钥与新密钥不同，已阻止覆盖');
    }
    await storage.write(
      slot,
      jsonEncode({
        'owner': owner,
        'scope': scope,
        'user': user,
        'vault_uid': vault.vaultUid,
        'device_uid': vault.deviceUid,
        'key': base64Encode(await vault.key.extractBytes()),
        'recovery': vault.recoveryEnvelope,
      }),
    );
  }

  Future<String> devicePublicKey(
    String scope,
    int user,
    String owner,
    String vault,
  ) async {
    final slot = '${_slot(scope, user, owner, vault)}.x25519';
    final raw = await storage.read(slot);
    if (raw != null) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return data['public'] as String;
    }
    final pair = await X25519().newKeyPair();
    final extracted = await pair.extract();
    final public = await pair.extractPublicKey();
    final result = base64Encode(public.bytes);
    await storage.write(
      slot,
      jsonEncode({'private': base64Encode(extracted.bytes), 'public': result}),
    );
    return result;
  }
}
