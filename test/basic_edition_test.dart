import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/services/screenshot_recognition.dart';

void main() {
  test(
    'explicit iOS basic configuration always hides screenshot recognition',
    () {
      expect(ScreenshotRecognition.enabled, isFalse);
    },
    skip:
        appFlavor == 'screenshot' &&
        !const bool.fromEnvironment('ACCOUNTING_DISABLE_SCREENSHOT'),
  );
}
