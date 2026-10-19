import 'sync_edit_guard.dart';
import 'pocketbase_api.dart';
import 'cloud_sync_store.dart';
import 'sync_protocol.dart';
import 'vault_key_store.dart';
import 'revision_crypto.dart';

class SyncCoordinator {
  final SyncTransport api;
  final CloudSyncStore store;
  final LocalVault vault;
  final void Function(String)? onProgress;
  Future<void>? _running;
  int deferredObjects = 0, appliedObjects = 0;
  int _upgradedAccounts = 0;
  SyncCoordinator(this.api, this.store, this.vault, {this.onProgress});
  void _assert(CloudBinding b) {
    if (api.ownerId != b.owner ||
        vault.vaultUid != b.vault ||
        vault.deviceUid != b.device) {
      throw const CloudSyncException('登录或设备状态已变化，已停止同步');
    }
  }

  Future<void> synchronize() {
    if (_running != null) return _running!;
    final task = _sync();
    _running = task;
    return task.whenComplete(() => _running = null);
  }

  Future<void> _pull(CloudBinding binding) async {
    onProgress?.call('正在下载并核对云端记录');
    for (var page = 0; page < 1700; page++) {
      _assert(binding);
      final state = (await store.binding())!;
      final response = await api.request(
        'GET',
        '/api/accounting/v1/pull',
        query: {
          'vault_uid': binding.vault,
          'device_uid': binding.device,
          'after': state.cursor.toString(),
          'limit': '30',
        },
      );
      _assert(binding);
      if (response['protocol'] != 1 ||
          response['last_seq'] is! int ||
          (response['last_seq'] as int) < state.cursor) {
        throw const SyncCryptoException('服务器历史发生回退，已停止同步');
      }
      final raw = List<Map<String, dynamic>>.from(
        (response['items'] as List).map(
          (r) => Map<String, dynamic>.from(r as Map),
        ),
      );
      final incoming = raw.map(EncryptedRevision.fromWire).toList();
      // Authenticate every item BEFORE the durable cursor can advance.
      for (final r in incoming) {
        if (r.changeSeq == null ||
            (r.changeSeq! > (response['last_seq'] as int))) {
          throw const SyncCryptoException('云端序号越界');
        }
        await r.decrypt(vault.key, binding.owner, binding.vault);
      }
      _assert(binding);
      await store.cache(binding, incoming);
      if (incoming.isEmpty) {
        if (state.cursor != (response['last_seq'] as int)) {
          throw const SyncCryptoException('云端历史缺失');
        }
        return;
      }
      if (incoming.last.changeSeq == response['last_seq']) return;
    }
    throw const CloudSyncException('云端版本较多，进度已保存，请再次同步');
  }

  Future<Map<String, Map<String, dynamic>>> _payloads(
    CloudBinding binding,
    List<EncryptedRevision> revisions,
  ) async {
    final result = <String, Map<String, dynamic>>{};
    for (final r in revisions) {
      result[r.revisionUid] = await r.decrypt(
        vault.key,
        binding.owner,
        binding.vault,
      );
    }
    return result;
  }

  Future<void> _project(CloudBinding b) async {
    onProgress?.call('正在合并到本机');
    final revisions = await store.all(b);
    final payloads = await _payloads(b, revisions);
    _assert(b);
    final projection = await store.project(b, payloads, revisions);
    appliedObjects += projection.applied;
    _upgradedAccounts += projection.upgradedAccounts;
    deferredObjects = projection.deferred;
  }

  Future<void> _sync() async {
    appliedObjects = 0;
    _upgradedAccounts = 0;
    final b = await store.binding();
    if (b == null) throw const CloudSyncException('请先连接加密空间');
    _assert(b);
    onProgress?.call('正在检查本机历史记录');
    await store.canonicalizeIdentities(vault.key, b.vault);
    // On a pristine join, hydrate cloud defaults before snapshotting B's local
    // seeded categories. This is never used over an existing local history.
    if (b.cursor == 0 && (await store.all(b)).isEmpty) {
      await _pull(b);
      await _project(b);
    }
    await _prepare(b);
    await _push(b);
    await _pull(b);
    await _project(b);
    final merged = await _mergeIdenticalAccounts(b);
    if (merged > 0 || _upgradedAccounts > 0) {
      await _prepare(b);
      await _push(b);
      await _pull(b);
      await _project(b);
    }
  }

  Future<void> _prepare(CloudBinding b) async {
    onProgress?.call('正在整理并加密本机记录');
    for (final change in await store.freeze()) {
      _assert(b);
      if (await store.prepared(b, change) != null) continue;
      final uid = newSyncId();
      final context = RevisionContext(
        ownerId: b.owner,
        vaultUid: b.vault,
        objectUid: change.objectUid,
        revisionUid: uid,
        parentUids: change.parents,
        keyEpoch: 1,
      );
      final encrypted = await RevisionCrypto().encrypt(
        change.payload,
        key: vault.key,
        context: context,
      );
      _assert(b);
      await store.savePrepared(
        b,
        change,
        EncryptedRevision(
          objectUid: change.objectUid,
          revisionUid: uid,
          parents: change.parents,
          envelope: encrypted,
        ),
      );
    }
  }

  Future<void> _push(CloudBinding b) async {
    onProgress?.call('正在上传加密记录');
    for (final r in await store.outgoing(b)) {
      _assert(b);
      final response = await api.request(
        'POST',
        '/api/accounting/v1/push',
        body: {
          'vault_uid': b.vault,
          'device_uid': b.device,
          'revision': r.toWire(),
        },
      );
      _assert(b);
      if (response['change_seq'] is! int) {
        throw const SyncCryptoException('上传确认无效');
      }
      await store.receipt(b, r, response['change_seq'] as int);
    }
  }

  Future<List<SyncConflict>> conflicts() async {
    final b = await store.binding();
    if (b == null) return [];
    _assert(b);
    final revisions = await store.all(b),
        groups = <String, List<EncryptedRevision>>{};
    for (final r in revisions) {
      groups.putIfAbsent(r.objectUid, () => []).add(r);
    }
    final result = <SyncConflict>[];
    for (final group in groups.entries) {
      final heads = revisionHeads(group.value);
      if (heads.length > 1) {
        final choices = <Map<String, dynamic>>[];
        for (final r in heads) {
          choices.add(await r.decrypt(vault.key, b.owner, b.vault));
        }
        result.add(SyncConflict(group.key, heads, choices));
      }
    }
    return result;
  }

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map)
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
    if (a is List && b is List)
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _same(a[i], b[i]));
    return a == b;
  }

  Future<int> _mergeIdenticalAccounts(CloudBinding b) async {
    if (SyncEditGuard.active) return 0;
    var merged = 0;
    for (final conflict in await conflicts()) {
      final value = conflict.choices.first;
      if (value['entity'] != 'asset_accounts' ||
          value['deleted'] != false ||
          (value['values'] as Map)['balance_offset_cents'] == null ||
          !conflict.choices.every((p) => _same(value, p)))
        continue;
      if ((await store.db.query(
        'local_sync_queue',
        where: 'object_uid = ?',
        whereArgs: [conflict.objectUid],
      )).isNotEmpty)
        continue;
      // Both upgraded devices may independently publish the same checkpoint.
      // Retain both parents; differing calibrations remain visible conflicts.
      await _mergeChoice(b, conflict, 0);
      merged++;
    }
    return merged;
  }

  Future<void> resolve(SyncConflict conflict, int choice) async {
    if (_running != null) throw const CloudSyncException('请等待当前同步完成');
    if (choice < 0 || choice >= conflict.heads.length) {
      throw const CloudSyncException('请选择一个冲突版本');
    }
    final b = (await store.binding())!;
    _assert(b);
    await _mergeChoice(b, conflict, choice);
    await synchronize();
  }

  Future<void> _mergeChoice(
    CloudBinding b,
    SyncConflict conflict,
    int choice,
  ) async {
    final uid = newSyncId(),
        parents = conflict.heads.map((r) => r.revisionUid).toList();
    final encrypted = await RevisionCrypto().encrypt(
      conflict.choices[choice],
      key: vault.key,
      context: RevisionContext(
        ownerId: b.owner,
        vaultUid: b.vault,
        objectUid: conflict.objectUid,
        revisionUid: uid,
        parentUids: parents,
        keyEpoch: 1,
      ),
    );
    _assert(b);
    await store.resolve(
      b,
      conflict,
      EncryptedRevision(
        objectUid: conflict.objectUid,
        revisionUid: uid,
        parents: parents,
        envelope: encrypted,
      ),
      conflict.choices[choice],
    );
  }
}
