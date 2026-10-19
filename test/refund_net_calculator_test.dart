import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:my_accounting_app/database/database_helper.dart';
import 'package:my_accounting_app/models/expense_record.dart';
import 'package:my_accounting_app/models/refund_net.dart';
import 'package:my_accounting_app/services/refund_plan_service.dart';
import 'package:my_accounting_app/services/bill_csv_service.dart';
import 'package:my_accounting_app/services/bill_file_reader.dart';

ExpenseRecord payment({double amount = 100, String key = '微信:ORDER001', int? id}) =>
    ExpenseRecord(id: id, userId: 1, ledgerId: 2, categoryId: 3, assetAccountId: 4,
      title: '原商品', note: '原备注', type: 'expense', amount: amount,
      date: DateTime(2026, 9, 15), importKey: key);

RefundEvidence cumulative(int amount, {int gross = 10000, String key = '微信:ORDER001'}) =>
    RefundEvidence(importKey: key, source: '微信', original: {'成功退款(元)': '${amount / 100}'},
      rowNumber: 2, grossCents: gross, cumulativeCents: amount, payment: payment(key: key));

RefundEvidence event(String id, int amount, {String key = '微信:ORDER001'}) =>
    RefundEvidence(importKey: key, source: '微信', original: {'退款号': id},
      rowNumber: 3, refundId: id, eventCents: amount, refundedAt: DateTime(2026, 10, 10));

Map<String, Object?> source({int refund = 0, String basis = 'none', bool manual = false, int? recordId = 10}) => {
  'id': 8, 'user_id': 1, 'import_key': '微信:ORDER001', 'gross_cents': 10000,
  'refund_cents': refund, 'basis': basis, 'snapshot_at': null, 'record_id': recordId,
  'manually_edited': manual ? 1 : 0, 'version': 2, 'original_json': '{}',
};

RefundPlanResult build(List<RefundEvidence> evidence, {List<Map<String, Object?>> records = const [],
    List<Map<String, Object?>> sources = const [], List<Map<String, Object?>> events = const [],
    Set<String> removed = const {}}) => RefundPlanService.build(userId: 1, evidence: evidence,
      recordRows: records, sourceRows: sources, eventRows: events, removedImportKeys: removed);

void main() {
  test('Decimal money remains exact without floating point rounding', () {
    expect(refundMoneyCents('￥1,234.56'), 123456);
    expect(refundMoneyCents('0.29'), 29);
    expect(refundMoneyCents('7'), 700);
    expect(refundMoneyCents('1.001'), isNull);
    expect(refundMoneyCents('1e2'), isNull);
    expect(refundMoneyCents('-0.01'), isNull);
  });

  test('A successful cumulative refund uses gross minus cumulative total', () {
    final result = RefundNetCalculator.cumulative(const RefundSourceState(grossCents: 10000),
      grossCents: 10000, refundedCents: 3000);
    expect(result.state!.netCents, 7000);
    final later = RefundNetCalculator.cumulative(result.state!, grossCents: 10000, refundedCents: 4000);
    expect(later.state!.netCents, 6000);
  });

  test('Historical cumulative snapshot cannot restore already refunded money', () {
    final result = RefundNetCalculator.cumulative(const RefundSourceState(grossCents: 10000,
      refundedCents: 3000, basis: 'cumulative'), grossCents: 10000, refundedCents: 1000);
    expect(result.duplicate, isTrue);
    expect(result.state!.netCents, 7000);
  });

  test('Older timestamp with a larger refund is left for review', () {
    final result = RefundNetCalculator.cumulative(RefundSourceState(grossCents: 10000,
      refundedCents: 3000, basis: 'cumulative', snapshotAt: DateTime(2026, 10, 10)),
      grossCents: 10000, refundedCents: 5000, snapshotAt: DateTime(2026, 10, 1));
    expect(result.reason, isNotNull);
  });

  test('A newer timestamp with a smaller cumulative refund needs review', () {
    final result = RefundNetCalculator.cumulative(RefundSourceState(grossCents: 10000,
      refundedCents: 3000, basis: 'cumulative', snapshotAt: DateTime(2026, 10, 10)),
      grossCents: 10000, refundedCents: 2000, snapshotAt: DateTime(2026, 10, 11));
    expect(result.reason, isNotNull);
  });

  test('An equal refund snapshot advances time but never moves backwards', () {
    final current = RefundSourceState(grossCents: 10000, refundedCents: 3000,
      basis: 'cumulative', snapshotAt: DateTime(2026, 10, 10));
    final newer = RefundNetCalculator.cumulative(current, grossCents: 10000,
      refundedCents: 3000, snapshotAt: DateTime(2026, 10, 11));
    final older = RefundNetCalculator.cumulative(newer.state!, grossCents: 10000,
      refundedCents: 3000, snapshotAt: DateTime(2026, 10, 9));
    expect(newer.state!.snapshotAt, DateTime(2026, 10, 11));
    expect(older.state!.snapshotAt, DateTime(2026, 10, 11));
  });

  test('Full refund is a retained transaction with zero net expense', () {
    final result = build([cumulative(10000)]);
    expect(result.failures, isEmpty);
    expect(result.plans.single.record.amount, 0);
    expect(result.plans.single.record.refundGrossCents, 10000);
    expect(result.plans.single.fullyRefunded, isTrue);
    expect(result.plans.single.record.importKey, '微信:ORDER001');
  });

  test('Excessive refund never creates a negative expense', () {
    final result = RefundNetCalculator.cumulative(const RefundSourceState(grossCents: 10000),
      grossCents: 10000, refundedCents: 10001);
    expect(result.state, isNull);
    expect(result.reason, isNotNull);
  });

  test('Independent refunds accumulate once by unique refund ID', () {
    final a = RefundNetCalculator.event(const RefundSourceState(grossCents: 10000), refundId: 'R1', amountCents: 2000);
    final b = RefundNetCalculator.event(a.state!, refundId: 'R2', amountCents: 1000);
    final repeated = RefundNetCalculator.event(b.state!, refundId: 'R1', amountCents: 2000);
    expect(b.state!.netCents, 7000);
    expect(repeated.state!.netCents, 7000);
    expect(repeated.duplicate, isTrue);
  });

  test('An existing refund ID with a changed amount requires review', () {
    final result = RefundNetCalculator.event(const RefundSourceState(grossCents: 10000,
      refundedCents: 2000, basis: 'events', events: {'R1': 2000}), refundId: 'R1', amountCents: 3000);
    expect(result.reason, isNotNull);
  });

  test('Cumulative snapshots and independent events never add together', () {
    final a = RefundNetCalculator.event(const RefundSourceState(grossCents: 10000,
      refundedCents: 3000, basis: 'cumulative'), refundId: 'R1', amountCents: 3000);
    final b = RefundNetCalculator.cumulative(const RefundSourceState(grossCents: 10000,
      refundedCents: 3000, basis: 'events', events: {'R1': 3000}), grossCents: 10000, refundedCents: 3000);
    expect(a.reason, isNotNull);
    expect(b.reason, isNotNull);
  });

  test('An explicit zero refund snapshot may safely begin independent events', () {
    final result = RefundNetCalculator.event(const RefundSourceState(grossCents: 10000,
      basis: 'cumulative'), refundId: 'R1', amountCents: 3000);
    expect(result.state!.netCents, 7000);
  });

  test('Manual amount adjustments are protected from automatic refunds', () {
    final result = RefundNetCalculator.cumulative(const RefundSourceState(grossCents: 10000,
      manuallyEdited: true), grossCents: 10000, refundedCents: 3000);
    expect(result.reason, isNotNull);
  });

  test('Refund in another month preserves original date account category and title', () {
    final existing = payment(id: 10).toMap();
    final result = build([event('R1', 3000)], records: [existing], sources: [source()]);
    final plan = result.plans.single;
    expect(plan.isNew, isFalse);
    expect(plan.record.amount, 70);
    expect(plan.record.date, DateTime(2026, 9, 15));
    expect(plan.record.categoryId, 3);
    expect(plan.record.assetAccountId, 4);
    expect(plan.record.title, '原商品');
    expect(plan.record.note, '原备注');
  });

  test('Refund row can precede original payment in the same file', () {
    final result = build([event('R1', 3000), cumulative(0)]);
    expect(result.failures, isEmpty);
    expect(result.plans.single.record.amount, 70);
    expect(result.plans.single.eventEvidence.length, 1);
  });

  test('Missing original payment retains refund for review', () {
    final result = build([event('R1', 3000)]);
    expect(result.plans, isEmpty);
    expect(result.failures.single.reason, contains('找不到'));
  });

  test('Legacy original gross payment is safely bootstrapped from explicit gross', () {
    final result = build([cumulative(3000)], records: [payment(id: 10).toMap()]);
    expect(result.plans.single.record.amount, 70);
    expect(result.plans.single.expectedSource, isNull);
  });

  test('Legacy changed amount is not guessed as original gross', () {
    final result = build([cumulative(3000)], records: [payment(id: 10, amount: 80).toMap()]);
    expect(result.plans, isEmpty);
    expect(result.failures.single.reason, contains('已经变化'));
  });

  test('An old original-payment file cannot revive a fully refunded bill', () {
    final record = payment(id: 10, amount: 0)
      ..refundGrossCents = 10000 ..refundTotalCents = 10000 ..refundBasis = 'cumulative';
    final evidence = RefundEvidence(importKey: '微信:ORDER001', source: '微信',
      original: const {}, rowNumber: 2, grossCents: 10000, payment: payment());
    final result = build([evidence], records: [record.toMap()], sources: [source(refund: 10000, basis: 'cumulative')]);
    expect(result.plans, isEmpty);
    expect(result.duplicates, 1);
    expect(record.amount, 0);
  });

  test('A deleted transaction with retained audit is never silently recreated', () {
    final result = build([cumulative(3000)], sources: [source(recordId: null)]);
    expect(result.plans, isEmpty);
    expect(result.failures.single.reason, contains('删除'));
  });

  test('Historical manual full-refund tombstone blocks a new payment plan', () {
    final result = build([cumulative(3000)], removed: {'微信:ORDER001'});
    expect(result.plans, isEmpty);
    expect(result.failures, hasLength(1));
  });

  test('The same refund ID cannot be applied to two orders in one preview', () {
    final result = build([cumulative(0), event('R1', 3000),
      cumulative(0, key: '微信:ORDER002'), event('R1', 3000, key: '微信:ORDER002')]);
    expect(result.plans, hasLength(2));
    expect(result.plans.first.record.amount, 100);
    expect(result.plans.last.record.amount, 100);
    expect(result.failures, hasLength(2));
    expect(result.failures.first.reason, contains('不同原订单'));
  });

  test('Conflicting cumulative totals within one file are all reviewed', () {
    final result = build([cumulative(2000), cumulative(3000)]);
    expect(result.plans, isEmpty);
    expect(result.failures, hasLength(2));
  });

  test('Latest equal-amount snapshot is included in a transaction plan', () {
    final record = payment(id: 10, amount: 70)
      ..refundGrossCents = 10000
      ..refundTotalCents = 3000
      ..refundBasis = 'cumulative';
    final previous = source(refund: 3000, basis: 'cumulative')
      ..['snapshot_at'] = DateTime(2026, 10, 1).toIso8601String();
    final item = RefundEvidence(importKey: '微信:ORDER001', source: '微信', original: const {},
      rowNumber: 2, grossCents: 10000, cumulativeCents: 3000,
      payment: payment(), snapshotAt: DateTime(2026, 10, 10));
    final result = build([item], records: [record.toMap()], sources: [previous]);
    expect(result.plans, hasLength(1));
    expect(result.plans.single.record.amount, 70);
    expect(result.plans.single.state.snapshotAt, DateTime(2026, 10, 10));
  });

  test('Preview leaves supplied local maps untouched and captures stale-check values', () {
    final record = payment(id: 10).toMap();
    final before = {...record};
    final result = build([cumulative(3000)], records: [record], sources: [source()]);
    expect(record, before);
    expect(result.plans.single.expectedRecord, before);
    final changed = {...record, 'title': '用户刚刚修改'};
    expect(RefundImportPlan.stableMap(changed), isNot(RefundImportPlan.stableMap(result.plans.single.expectedRecord)));
  });

  test('CSV net export provenance is protected when refund events are unavailable', () {
    final record = payment(id: 10, amount: 70)
      ..refundGrossCents = 10000 ..refundTotalCents = 3000 ..refundBasis = 'export';
    final result = build([event('R2', 1000)], records: [record.toMap()], sources: [source(refund: 3000, basis: 'export')]);
    expect(result.plans, isEmpty);
    expect(result.failures.single.reason, contains('CSV'));
  });

  test('CSV exports a manually adjusted amount without inconsistent refund provenance', () {
    final record = payment(id: 10, amount: 85)
      ..refundGrossCents = 10000
      ..refundTotalCents = 2000
      ..refundBasis = 'cumulative';
    final csv = BillCsvService(DatabaseHelper()).encode([record]);
    final row = BillFileReader.read('账单.csv', utf8.encode(csv)).single.rows.single;
    expect(double.parse(row[3]), 85);
    expect(row.skip(11), ['', '', '']);
    expect(record.refundGrossCents, 10000);
    expect(record.refundTotalCents, 2000);
  });

  test('CSV does not attach old expense refund provenance to a manually changed income', () {
    final record = payment(id: 10, amount: 80)
      ..type = 'income'
      ..refundGrossCents = 10000
      ..refundTotalCents = 2000
      ..refundBasis = 'cumulative';
    final csv = BillCsvService(DatabaseHelper()).encode([record]);
    final row = BillFileReader.read('账单.csv', utf8.encode(csv)).single.rows.single;
    expect(row[2], 'income');
    expect(double.parse(row[3]), 80);
    expect(row.skip(11), ['', '', '']);
  });
}
