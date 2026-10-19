import 'package:flutter/services.dart';

class ScreenshotRecognition {
  static const enabled =
      appFlavor == 'screenshot' &&
      !bool.fromEnvironment('ACCOUNTING_DISABLE_SCREENSHOT');
  static const _channel = MethodChannel('accounting/screenshot');
  Future<String?> pickAndRecognize() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'pickAndRecognize',
    );
    if (result?['cancelled'] == true) return null;
    return (result?['text'] as String? ?? '').trim();
  }
}
