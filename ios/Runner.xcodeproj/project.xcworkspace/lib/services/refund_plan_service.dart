import '../models/expense_record.dart';
import '../models/refund_net.dart';

class RefundEvidenceFailure {
  final RefundEvidence evidence;
  final String reason;
  const RefundEvidenceFailure(this.evidence, this.reason);
}

class RefundPlanResult {
  final List<RefundImportPlan> plans;
  final List<RefundEvidenceFailure> failures;
  final int duplicates;
  const RefundPlanResult(this.plans, this.failures, this.duplicates);
}

/// Builds a read-only plan from a consistent local snapshot.
class RefundPlanService {
  static RefundPlanResult build({required int userId, required List<RefundEvidence> evidence,
    required List<Map<String, Object?>> recordRows,
    required List<Map<String, Object?>> sourceRows,
    required List<Map<String, Object?>> eventRows,
    required Set<String> removedImportKeys}) {
    final groups = <String, List<RefundEvidence>>{};
    for (final item in evidence) {
      groups.putIfAbsent(item.importKey, () => []).add(item);
    }
    final sources = {for (final row in sourceRows) row['import_key'] as String: row};
    final eventSignatures = <String, Set<String>>{};
    for (final item in evidence.where((e) => e.isEvent)) {
      eventSignatures.putIfAbsent('${item.source}:${item.refundId}', () => {})
          .add('${item.importKey}:${item.eventCents}');
    }
    final conflictingEventIds = eventSignatures.entries.where((e) => e.value.length > 1)
        .map((e) => e.key).toSet();
    final failures = <RefundEvidenceFailure>[];
    final plans = <RefundImportPlan>[];
    final acceptedEventIds = <String, RefundEvidence>{};
    var duplicates = 0;
    for (final entry in groups.entries) {
      final items = entry.value;
      final matching = recordRows.where((r) => r['import_key'] == entry.key).toList();
      final originalSource = sources[entry.key];
      final originalEvents = eventRows.where((r) => r['import_key'] == entry.key).toList()
        ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
      if (matching.length > 1) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '本地存在多笔相同来源订单，请先核对')));
        continue;
      }
      final originalRecord = matching.isEmpty ? null : matching.single;
      final payments = items.where((e) => !e.isEvent).toList();
      final fallback = payments.isEmpty ? null : payments.first.payment;
      if (removedImportKeys.contains(entry.key) ||
          (originalSource != null && originalRecord == null)) {
        for (final item in items) {
          if (item.isEvent || (item.cumulativeCents ?? 0) > 0) {
            failures.add(RefundEvidenceFailure(item, '原账单已撤销或删除，请核对，不会自动恢复'));
          } else { duplicates++; }
        }
        continue;
      }
      if (originalRecord == null && fallback == null) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '找不到退款对应的原支出，请先导入原付款账单')));
        continue;
      }
      final baseRecord = originalRecord == null ? fallback!
          : ExpenseRecord.fromMap(Map<String, dynamic>.from(originalRecord));
      final grossValues = payments.map((e) => e.grossCents).whereType<int>().toSet();
      if (grossValues.length > 1) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '同一原订单出现不同原付款金额')));
        continue;
      }
      final gross = originalSource?['gross_cents'] as int? ??
          (baseRecord.refundGrossCents ?? (grossValues.isEmpty ? null : grossValues.single));
      if (baseRecord.type != 'expense' || gross == null || gross <= 0) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '原订单不是可确认金额的支出，无法自动扣减退款')));
        continue;
      }
      final currentCents = refundMoneyCents(baseRecord.amount.toStringAsFixed(2));
      if (originalSource == null && baseRecord.refundGrossCents == null && currentCents != gross) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '原账单金额已经变化，无法确认原付款金额')));
        continue;
      }
      var state = RefundSourceState(grossCents: gross,
        refundedCents: originalSource?['refund_cents'] as int? ?? baseRecord.refundTotalCents ?? 0,
        basis: originalSource?['basis'] as String? ?? baseRecord.refundBasis ?? 'none',
        snapshotAt: originalSource?['snapshot_at'] == null ? null
            : DateTime.parse(originalSource!['snapshot_at'] as String),
        manuallyEdited: originalSource?['manually_edited'] == 1,
        version: originalSource?['version'] as int? ?? 0,
        events: {for (final row in originalEvents)
          row['refund_id'] as String: row['amount_cents'] as int});
      final savedEventTotal = state.events.values.fold<int>(0, (a, b) => a + b);
      if (originalSource != null &&
          (originalSource['record_id'] != originalRecord?['id'] ||
            (state.basis == 'events' && savedEventTotal != state.refundedCents) ||
            (state.basis != 'events' && originalEvents.isNotEmpty))) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '本地退款来源与事件历史不一致，请核对')));
        continue;
      }
      if (originalRecord != null && currentCents != state.netCents) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '本地金额与退款来源记录不一致，可能已手动调整')));
        continue;
      }
      if (state.basis == 'export' && items.any((e) => e.isEvent || e.cumulativeCents != null)) {
        failures.addAll(items.map((e) => RefundEvidenceFailure(e, '此订单来自净额CSV，缺少原退款历史，请核对后续退款')));
        continue;
      }
      var accepted = 0;
      var auditOriginal = items.first.original;
      final eventEvidence = <RefundEvidence>[];
      final snapshotTotals = payments.map((e) => e.cumulativeCents).whereType<int>().toSet();
      for (final item in [...payments, ...items.where((e) => e.isEvent)]) {
        RefundNetDecision decision;
        if (item.isEvent) {
          final eventIdentity = '${item.source}:${item.refundId}';
          if (conflictingEventIds.contains(eventIdentity)) {
            failures.add(RefundEvidenceFailure(item, '同一文件的退款单号对应不同原订单或金额，全部留待核对'));
            continue;
          }
          final previousInFile = acceptedEventIds[eventIdentity];
          if (previousInFile != null && (previousInFile.importKey != item.importKey || previousInFile.eventCents != item.eventCents)) {
            failures.add(RefundEvidenceFailure(item, '同一文件的退款单号对应不同原订单或金额'));
            continue;
          }
          final sameId = eventRows.where((r) => r['source'] == item.source && r['refund_id'] == item.refundId).toList();
          if (sameId.any((r) => r['import_key'] != item.importKey || r['amount_cents'] != item.eventCents)) {
            failures.add(RefundEvidenceFailure(item, '退款单号已关联另一订单或金额，不能重复扣减'));
            continue;
          }
          decision = RefundNetCalculator.event(state, refundId: item.refundId!, amountCents: item.eventCents!);
        } else if (item.cumulativeCents != null) {
          if (snapshotTotals.length > 1) {
            failures.add(RefundEvidenceFailure(item, '同一文件的原订单有不同累计退款金额，请核对'));
            continue;
          }
          decision = RefundNetCalculator.cumulative(state, grossCents: item.grossCents!,
            refundedCents: item.cumulativeCents!, snapshotAt: item.snapshotAt);
        } else {
          if (item.grossCents != state.grossCents) {
            decision = const RefundNetDecision.review('原付款金额与保存的订单不一致');
          } else {
            // Ordinary/old statements retain the latest known refund result.
            decision = RefundNetDecision.accept(state, duplicate: originalSource != null);
          }
        }
        if (decision.reason != null) {
          failures.add(RefundEvidenceFailure(item, decision.reason!));
          continue;
        }
        if (decision.duplicate) duplicates++;
        state = decision.state!;
        accepted++;
        if (!decision.duplicate) auditOriginal = item.original;
        if (item.isEvent && !decision.duplicate) {
          eventEvidence.add(item);
          acceptedEventIds['${item.source}:${item.refundId}'] = item;
        }
      }
      if (accepted == 0) continue;
      final unchanged = originalSource != null && originalRecord != null &&
          originalSource['gross_cents'] == state.grossCents &&
          originalSource['refund_cents'] == state.refundedCents &&
          originalSource['basis'] == state.basis &&
          originalSource['snapshot_at'] == state.snapshotAt?.toIso8601String() && eventEvidence.isEmpty;
      if (unchanged) continue;
      final map = baseRecord.toMap();
      map['amount'] = state.netCents / 100;
      map['refund_gross_cents'] = state.grossCents;
      map['refund_total_cents'] = state.refundedCents;
      map['refund_basis'] = state.basis;
      map['is_synced'] = 0;
      map['user_id'] = userId;
      final record = ExpenseRecord.fromMap(map);
      plans.add(RefundImportPlan(importKey: entry.key, record: record,
        expectedRecord: originalRecord == null ? null : Map<String, Object?>.from(originalRecord),
        expectedSource: originalSource == null ? null : Map<String, Object?>.from(originalSource),
        expectedEvents: originalEvents.map((e) => Map<String, Object?>.from(e)).toList(), state: state, original: auditOriginal,
        source: items.first.source, eventEvidence: eventEvidence));
    }
    return RefundPlanResult(plans, failures, duplicates);
  }
}
