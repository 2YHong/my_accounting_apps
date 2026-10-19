import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'full_backup_service.dart';

class CloudAccountService {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const maxBytes = 8 * 1024 * 1024;
  static Future<void>? _initializing;
  static bool get configured => url.isNotEmpty && key.isNotEmpty;
  SupabaseClient get client => Supabase.instance.client;
  String get uid =>
      client.auth.currentUser?.id ??
      (throw const FullBackupException('请先登录云账号'));

  Future<void> initialize() async {
    if (!configured) throw const FullBackupException('云服务尚未配置，请按接入说明配置后重新安装');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FullBackupException('云服务地址必须是有效的 HTTPS 地址');
    }
    try {
      await (_initializing ??= Supabase.initialize(
        url: url,
        publishableKey: key,
        authOptions: FlutterAuthClientOptions(
          localStorage: SecureCloudSession('accounting.session.${uri.host}'),
          detectSessionInUri: false,
        ),
      ).then((_) {}));
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  Future<void> sendCode(String email) =>
      client.auth.signInWithOtp(email: email);
  Future<void> verify(String email, String code) async {
    final result = await client.auth.verifyOTP(
      email: email,
      token: code,
      type: OtpType.email,
    );
    if (result.session == null) {
      throw const FullBackupException('登录未完成，请重新获取验证码');
    }
  }

  Future<void> signOut() => client.auth.signOut(scope: SignOutScope.local);

  void assertUser(String owner) {
    if (uid != owner) throw const FullBackupException('登录状态已改变，请重新操作');
  }

  Future<CloudSnapshot?> fetch({bool withPayload = false}) async {
    final owner = uid;
    final row = await client
        .from('accounting_cloud_snapshots')
        .select(
          withPayload ? 'revision,updated_at,payload' : 'revision,updated_at',
        )
        .eq('user_id', owner)
        .maybeSingle();
    assertUser(owner);
    return row == null ? null : CloudSnapshot.fromJson(row);
  }

  Future<int> upload(
    Uint8List bytes,
    int expectedRevision,
    String owner,
  ) async {
    assertUser(owner);
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FullBackupException('云备份最大支持 8 MB，请使用本地完整备份保存较大的数据');
    }
    final result = await client.rpc(
      'save_accounting_snapshot',
      params: {
        'p_expected_revision': expectedRevision,
        'p_payload': base64Encode(bytes),
      },
    );
    assertUser(owner);
    if (result is! int || result <= expectedRevision) {
      throw const FullBackupException('云端返回了无效版本，请重新检查云端状态');
    }
    return result;
  }
}

class CloudSnapshot {
  final int revision;
  final DateTime updatedAt;
  final Uint8List? bytes;
  const CloudSnapshot(this.revision, this.updatedAt, this.bytes);
  factory CloudSnapshot.fromJson(Map<String, dynamic> row) {
    final revision = row['revision'];
    final time = row['updated_at'];
    if (revision is! int ||
        revision < 1 ||
        time is! String ||
        DateTime.tryParse(time) == null) {
      throw const FullBackupException('云备份信息无效');
    }
    Uint8List? bytes;
    final payload = row['payload'];
    if (payload != null) {
      if (payload is! String ||
          payload.length > ((CloudAccountService.maxBytes + 2) ~/ 3) * 4) {
        throw const FullBackupException('云备份超过支持大小');
      }
      try {
        bytes = base64Decode(payload);
      } catch (_) {
        throw const FullBackupException('云备份内容损坏');
      }
      if (bytes.isEmpty || bytes.length > CloudAccountService.maxBytes) {
        throw const FullBackupException('云备份大小无效');
      }
    }
    return CloudSnapshot(revision, DateTime.parse(time), bytes);
  }
}

// Auth tokens stay out of SharedPreferences and full accounting backups.
class SecureCloudSession extends LocalStorage {
  final String sessionKey;
  final FlutterSecureStorage storage;
  const SecureCloudSession(
    this.sessionKey, {
    this.storage = const FlutterSecureStorage(),
  });
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async =>
      await storage.containsKey(key: sessionKey);
  @override
  Future<String?> accessToken() => storage.read(key: sessionKey);
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: sessionKey, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => storage.delete(key: sessionKey);
}
