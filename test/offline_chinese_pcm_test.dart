import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/offline_chinese_recognizer.dart';

void main() {
  test('PCM16LE符号和归一化正确', () {
    final decoder = Pcm16LeDecoder();
    expect(decoder.convert(Uint8List.fromList([0,0,0xff,0x7f,0,0x80,0xff,0xff])),
      orderedEquals([0.0,32767 / 32768,-1.0,-1 / 32768]));
  });
  test('任意半样本分块与连续转换相同', () {
    final bytes = Uint8List.fromList([0,0x80,0xff,0x7f,0x34,0x12,0xff,0xff]);
    final whole = Pcm16LeDecoder().convert(bytes);
    for (var split = 0; split <= bytes.length; split++) {
      final decoder = Pcm16LeDecoder();
      final samples = [...decoder.convert(Uint8List.sublistView(bytes,0,split)),
        ...decoder.convert(Uint8List(0)),...decoder.convert(Uint8List.sublistView(bytes,split))];
      expect(samples,orderedEquals(whole));
    }
  });
  test('取消和新录音不会复用上次的半字节', () {
    final decoder = Pcm16LeDecoder();
    expect(decoder.convert(Uint8List.fromList([0xff])),isEmpty);
    decoder.reset();
    expect(decoder.convert(Uint8List.fromList([0,0x80])),orderedEquals([-1.0]));
  });
  test('中文和金额相邻空格合并，英文名称和小数保留', () {
    expect(normalizeOfflineChineseText('今 天 买 了 牛 奶 花 了 7 . 5 元'), '今天买了牛奶花了7.5元');
    expect(normalizeOfflineChineseText('买了 New Balance 鞋花了 199 元'), '买了 New Balance 鞋花了199元');
  });
}
