import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'revision_crypto.dart';

class EncryptedRevision {
  final String objectUid, revisionUid;
  final List<String> parents;
  final Map<String, dynamic> envelope;
  final int? changeSeq;
  EncryptedRevision({
    required this.objectUid,
    required this.revisionUid,
    required List<String> parents,
    required Map<String, dynamic> envelope,
    this.changeSeq,
  }) : parents = List.unmodifiable(List<String>.from(parents)..sort()),
       envelope = Map.unmodifiable(envelope);
  factory EncryptedRevision.fromWire(Map<String, dynamic> map) {
    final parents = List<String>.from(map['parent_uids'] as List);
    final env = <String, dynamic>{
      for (final k in RevisionCrypto.envelopeKeys) k: map[k],
    };
    final value = EncryptedRevision(
      objectUid: map['object_uid'] as String,
      revisionUid: map['revision_uid'] as String,
      parents: parents,
      envelope: env,
      changeSeq: map['change_seq'] as int?,
    );
    if (value.changeSeq != null && value.changeSeq! < 1) {
      throw const SyncCryptoException('云端序号无效');
    }
    return value;
  }
  Map<String, dynamic> toWire() => {
    'object_uid': objectUid,
    'revision_uid': revisionUid,
    'parent_uids': parents,
    ...envelope,
  };
  RevisionContext context(String owner, String vault) => RevisionContext(
    ownerId: owner,
    vaultUid: vault,
    objectUid: objectUid,
    revisionUid: revisionUid,
    parentUids: parents,
    keyEpoch: envelope['key_epoch'] as int,
    formatVersion: envelope['format_version'] as int,
  );
  Future<Map<String, dynamic>> decrypt(
    SecretKey key,
    String owner,
    String vault,
  ) => RevisionCrypto().decrypt(
    envelope,
    key: key,
    context: context(owner, vault),
  );
  bool sameContent(EncryptedRevision other) =>
      canonical(toWire()) == canonical(other.toWire());
  static String canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(canonical).join(',')}]';
    return jsonEncode(value);
  }
}

List<EncryptedRevision> revisionHeads(Iterable<EncryptedRevision> revisions) {
  final list = revisions.toList(),
      seen = <String, EncryptedRevision>{},
      parents = <String>{};
  for (final r in list) {
    if (seen.containsKey(r.revisionUid) &&
        !seen[r.revisionUid]!.sameContent(r)) {
      throw const SyncCryptoException('同一版本标识出现不同内容');
    }
    seen[r.revisionUid] = r;
    parents.addAll(r.parents);
  }
  for (final r in list) {
    for (final p in r.parents) {
      final parent = seen[p];
      if (parent == null || parent.objectUid != r.objectUid) {
        throw const SyncCryptoException('云端版本历史不完整或关联错误');
      }
    }
  }
  final remaining = <String, int>{}, children = <String, List<String>>{};
  for (final r in seen.values) {
    remaining[r.revisionUid] = r.parents.length;
    for (final p in r.parents) {
      final parent = seen[p]!;
      if (parent.changeSeq != null &&
          r.changeSeq != null &&
          parent.changeSeq! >= r.changeSeq!) {
        throw const SyncCryptoException('版本历史的先后顺序无效');
      }
      children.putIfAbsent(p, () => []).add(r.revisionUid);
    }
  }
  final ready = remaining.keys.where((k) => remaining[k] == 0).toList();
  for (var i = 0; i < ready.length; i++) {
    for (final child in children[ready[i]] ?? <String>[]) {
      remaining[child] = remaining[child]! - 1;
      if (remaining[child] == 0) ready.add(child);
    }
  }
  if (ready.length != seen.length) throw const SyncCryptoException('版本历史存在循环');

  return seen.values.where((r) => !parents.contains(r.revisionUid)).toList();
}

class SyncConflict {
  final String objectUid;
  final List<EncryptedRevision> heads;
  final List<Map<String, dynamic>> choices;
  SyncConflict(this.objectUid, this.heads, this.choices);
}
