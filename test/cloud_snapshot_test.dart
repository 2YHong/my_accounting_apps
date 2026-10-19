import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/pages/cloud_account_page.dart';
import 'package:my_accounting_app/services/cloud_account_service.dart';
import 'package:my_accounting_app/services/full_backup_service.dart';

void main() {
  testWidgets(
    'missing cloud configuration leaves accounting offline and shows setup guidance',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CloudAccountPage()));
      await tester.pumpAndSettle();
      expect(find.text('登录与云同步'), findsOneWidget);
      expect(find.textContaining('云服务尚未配置'), findsOneWidget);
      expect(find.text('加密上传本机数据'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test('cloud metadata and encrypted payload parse correctly', () {
    final value = CloudSnapshot.fromJson({
      'revision': 3,
      'updated_at': '2026-10-14T08:00:00Z',
      'payload': base64Encode([1, 2, 3]),
    });
    expect(value.revision, 3);
    expect(value.bytes, [1, 2, 3]);
    expect(
      CloudSnapshot.fromJson({
        'revision': 1,
        'updated_at': '2026-10-14T08:00:00Z',
      }).bytes,
      isNull,
    );
  });
  test('invalid cloud revisions dates and payloads are rejected', () {
    for (final patch in [
      {'revision': 0},
      {'revision': '1'},
      {'updated_at': 'bad'},
      {'payload': ''},
      {'payload': '%invalid%'},
      {'payload': 12},
    ]) {
      expect(
        () => CloudSnapshot.fromJson({
          'revision': 1,
          'updated_at': '2026-10-14T08:00:00Z',
          ...patch,
        }),
        throwsA(isA<FullBackupException>()),
      );
    }
  });
}
