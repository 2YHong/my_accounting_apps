import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/asset_notifications.dart';
import '../services/ledger_notifications.dart';
import '../services/bill_csv_service.dart';
import '../services/recurring_notifications.dart';
import 'pocketbase_api.dart';
import 'local_sync_repository.dart';
import 'cloud_sync_store.dart';
import 'sync_coordinator.dart';
import 'sync_protocol.dart';
import 'vault_key_store.dart';
import 'revision_crypto.dart';

class PocketSyncController extends ChangeNotifier {
  static final instance = PocketSyncController();
  final PocketBaseApi api;
  final CloudVaultKeys cloudKeys;
  final VaultKeyStore localKeys;
  PocketSyncController({
    PocketBaseApi? api,
    CloudVaultKeys? cloudKeys,
    VaultKeyStore? localKeys,
  }) : api = api ?? PocketBaseApi(),
       cloudKeys = cloudKeys ?? CloudVaultKeys(),
       localKeys = localKeys ?? VaultKeyStore();
  SyncCoordinator _newEngine(LocalVault key) => SyncCoordinator(
    api,
    _store!,
    key,
    onProgress: (step) {
      message = step;
      if (kDebugMode) debugPrint('[加密同步] $step');
      notifyListeners();
    },
  );
  CloudSyncStore? _store;
  SyncCoordinator? _engine;
  Map<String, dynamic>? remote;
  List<SyncConflict> conflicts = [];
  bool busy = false;
  Timer? _timer;
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  void _startAuto() {
    if (!connected) return;
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!busy && connected) sync();
    });
  }

  String message = '登录后仍需主动连接加密空间；本机账单不会自动上传。';
  String? get owner => api.ownerId;
  String? get accountEmail => api.accountEmail;
  bool get connected => _engine != null;
  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      message = e is CloudSyncException
          ? e.message
          : e is SyncCryptoException
          ? e.message
          : '同步未完成，本机数据已保留，请检查网络或关联数据后重试';
      if (kDebugMode) debugPrint('[加密同步] $message');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> initialize() => _run(() async {
    _engine = null;
    _store = await CloudSyncStore.open();
    final binding = await _store!.binding();
    await api.loadSession();
    if (binding != null) {
      if (owner == binding.owner) {
        final key = await cloudKeys.load(
          _store!.scope,
          _store!.user,
          binding.owner,
          binding.vault,
        );
        if (key != null) _engine = _newEngine(key);
      }
    }
    if (owner != null) await _loadRemote();
    _startAuto();
  });
  Future<void> login(String email, String password, {bool register = false}) =>
      _run(() async {
        _engine = null;
        conflicts = [];
        _store = await CloudSyncStore.open();
        if (register) {
          await api.registerForVerification(email, password);
          message = '验证码已发送，请填写邮件中的 6 位数字完成验证。';
          return;
        } else {
          await api.login(email, password);
        }
        final binding = await _store!.binding();
        if (binding != null && binding.owner != owner) {
          throw const CloudSyncException('本机账单属于另一个云账号，已阻止混合上传；请登录原账号');
        }
        await _loadRemote();
        message = '登录成功。请主动连接或解锁加密空间后再同步。';
      });
  Future<void> refreshEmailVerification() => _run(() async {
    await api.loadSession();
    message = api.emailVerified == true
        ? '邮箱已验证，以后发送恢复码无需再次验证。'
        : '邮箱尚未验证，请填写邮件中的验证码。';
  });

  Future<void> _loadRemote() async {
    remote = await api.request('GET', '/api/accounting/v1/vault');
    final vault = remote!['vault'];
    final binding = await _store!.binding();
    if (vault is Map &&
        binding != null &&
        binding.owner == owner &&
        binding.vault == vault['vault_uid']) {
      final key = await cloudKeys.load(
        _store!.scope,
        _store!.user,
        owner!,
        vault['vault_uid'] as String,
      );
      if (key != null) _engine = _newEngine(key);
    }
  }

  Future<void> connect({String? recoveryCode}) => _run(() async {
    if (owner == null) throw const CloudSyncException('请先登录');
    final expectedOwner = owner!;
    _store ??= await CloudSyncStore.open();
    final existingBinding = await _store!.binding();
    if (existingBinding != null && existingBinding.owner != expectedOwner) {
      throw const CloudSyncException('本机数据已绑定其他云账号，已阻止连接');
    }
    await _loadRemote();
    final map = remote!['vault'];
    LocalVault vault;
    if (map == null) {
      final local = await localKeys.load(_store!.scope, _store!.user);
      if (local == null) {
        throw const CloudSyncException('请先在“同步加密与恢复码”生成密钥并保存恢复码');
      }
      vault = local;
      final pub = await cloudKeys.devicePublicKey(
        _store!.scope,
        _store!.user,
        expectedOwner,
        vault.vaultUid,
      );
      await api.request(
        'POST',
        '/api/accounting/v1/initialize',
        body: {
          'vault_uid': vault.vaultUid,
          'device_uid': vault.deviceUid,
          'public_key': pub,
          'recovery': vault.recoveryEnvelope,
        },
      );
    } else {
      final uid = (map as Map)['vault_uid'] as String;
      final saved = await cloudKeys.load(
        _store!.scope,
        _store!.user,
        expectedOwner,
        uid,
      );
      final local = await localKeys.load(_store!.scope, _store!.user);
      if (saved != null) {
        vault = saved;
      } else if (local != null && local.vaultUid == uid) {
        vault = local;
      } else {
        if (recoveryCode == null || recoveryCode.trim().isEmpty) {
          throw const CloudSyncException('此云空间需要原恢复码解锁；不要生成新密钥覆盖它');
        }
        final envelope = Map<String, dynamic>.from(remote!['recovery'] as Map);
        if (envelope['vault_uid'] != uid) {
          throw const SyncCryptoException('云端密钥包归属不一致');
        }
        final key = await RecoveryCrypto.unwrap(envelope, recoveryCode);
        vault = LocalVault(
          vaultUid: uid,
          deviceUid: newSyncId(),
          key: key,
          recoveryEnvelope: envelope,
        );
      }
      await cloudKeys.save(_store!.scope, _store!.user, expectedOwner, vault);
      final pub = await cloudKeys.devicePublicKey(
        _store!.scope,
        _store!.user,
        expectedOwner,
        uid,
      );
      await api.request(
        'POST',
        '/api/accounting/v1/device',
        body: {
          'vault_uid': uid,
          'device_uid': vault.deviceUid,
          'public_key': pub,
        },
      );
    }
    if (owner != expectedOwner) throw const CloudSyncException('账号状态已变化');
    await cloudKeys.save(_store!.scope, _store!.user, expectedOwner, vault);
    await _store!.bind(expectedOwner, vault.vaultUid, vault.deviceUid);
    _engine = _newEngine(vault);
    _startAuto();
    message = '加密空间已连接并开启前台自动同步，也可手动立即同步。';
  });
  Future<void> sync() => _run(() async {
    if (_engine == null) throw const CloudSyncException('请先连接或解锁加密空间');
    try {
      await _engine!.synchronize();
      message = _engine!.deferredObjects == 0
          ? '同步完成'
          : '已接收数据；关闭编辑页面后再次同步，部分关联可能需先处理冲突';
    } finally {
      conflicts = await _engine!.conflicts();
      if (conflicts.isNotEmpty) {
        message = '有 ${conflicts.length} 个对象存在冲突，请选择保留的版本';
      }
      if (_engine!.appliedObjects > 0) _notifyCloudChanges();
    }
  });
  Future<void> resolve(SyncConflict conflict, int choice) => _run(() async {
    try {
      await _engine!.resolve(conflict, choice);
      message = '已保存选择并同步，双方历史版本仍保留';
    } finally {
      conflicts = await _engine!.conflicts();
      _notifyCloudChanges();
    }
  });
  void _notifyCloudChanges() {
    // Refresh retained pages through their existing listeners, keeping navigation,
    // the selected month and scroll position intact.
    notifyLedgersChanged();
    notifyAssetAccountsChanged();
    billDataRevision.value++;
    recurringDataRevision.value++;
  }

  Future<void> logout() => _run(() async {
    pause();
    await api.logout();
    _engine = null;
    remote = null;
    conflicts = [];
    message = '已退出，本机数据和云端副本均保留';
  });
  Future<void> onResume() async {
    if (busy) return;
    if (_store != null) {
      final state = await LocalSyncRepository().status();
      if (state.installationScope != _store!.scope ||
          state.userId != _store!.user) {
        pause();
        _engine = null;
        _store = null;
      }
    }
    if (_store == null) await initialize();
    _startAuto();
    if (connected && !busy) await sync();
  }
}
