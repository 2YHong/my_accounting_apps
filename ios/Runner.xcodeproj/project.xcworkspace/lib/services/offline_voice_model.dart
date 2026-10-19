import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class OfflineVoiceModel {
  static Future<Map<String, String>>? _preparing;
  static const _assets = <String, _ModelAsset>{
    'encoder': _ModelAsset(
      'encoder-epoch-99-avg-1.int8.onnx', 21621684,
      '1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1',
    ),
    'decoder': _ModelAsset(
      'decoder-epoch-99-avg-1.onnx', 7509745,
      '5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78',
    ),
    'joiner': _ModelAsset(
      'joiner-epoch-99-avg-1.int8.onnx', 1795562,
      'a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169',
    ),
    'tokens': _ModelAsset(
      'tokens.txt', 48697,
      '8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac',
    ),
  };

  static Future<Map<String, String>> prepare() {
    final pending = _preparing;
    if (pending != null) return pending;
    late final Future<Map<String, String>> task;
    task = _prepare().whenComplete(() {
      // Share an in-flight copy. A later call can validate the disk cache again,
      // and a failed extraction never remains cached as a failed Future.
      if (identical(_preparing, task)) _preparing = null;
    });
    _preparing = task;
    return task;
  }

  static Future<Map<String, String>> _prepare() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(
      support.path, 'voice_models', 'zh-14m-2023-02-23',
    ));
    await directory.create(recursive: true);
    final paths = <String, String>{};
    for (final entry in _assets.entries) {
      final asset = entry.value;
      final cached = File(p.join(directory.path, asset.name));
      if (!await _validFile(cached, asset)) {
        final temporary = File('${cached.path}.part');
        try {
          final data = await rootBundle.load('assets/voice/zh-14m/${asset.name}');
          final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          if (bytes.length != asset.length) {
            throw StateError('内置中文语音模型大小不正确，请重新安装软件');
          }
          await temporary.writeAsBytes(bytes, flush: true);
          if (!await _validFile(temporary, asset)) {
            throw StateError('内置中文语音模型校验失败，请重新安装软件');
          }
          // Both files are on the same filesystem. Only a fully verified model
          // replaces the cached file; interrupted copies remain .part files.
          await temporary.rename(cached.path);
        } finally {
          if (await temporary.exists()) {
            try { await temporary.delete(); } catch (_) { /* Retry replaces a stale partial file. */ }
          }
        }
      }
      paths[entry.key] = cached.absolute.path;
    }
    return Map<String, String>.unmodifiable(paths);
  }

  static Future<bool> _validFile(File file, _ModelAsset asset) => compute(
    _validateModelFile,
    <String, Object>{'path': file.path, 'length': asset.length, 'sha256': asset.sha256},
  );
}

class _ModelAsset {
  final String name;
  final int length;
  final String sha256;
  const _ModelAsset(this.name, this.length, this.sha256);
}

Future<bool> _validateModelFile(Map<String, Object> input) async {
  final file = File(input['path'] as String);
  try {
    if (!await file.exists() || await file.length() != input['length']) return false;
    final bytes = await file.readAsBytes();
    if (bytes.length != input['length']) return false;
    final digest = await Sha256().hash(bytes);
    final hex = digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return hex == input['sha256'];
  } on FileSystemException {
    return false;
  }
}
