import 'dart:convert';

import 'expense_record.dart';

/// Money is parsed from its decimal spelling, never rounded from a double.
int? refundMoneyCents(String value) {
  final cleaned = value.replaceAll(RegExp(r'[¥￥,，\s]'), '');
  final match = RegExp(r'^\+?(\d+)(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final whole = int.tryParse(match[1]!);
  if (whole == null || whole > 9000000000000) return null;
  return whole * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
}

class RefundSourceState {
  final int grossCents;
  final int refundedCents;
  final String basis;
  final DateTime? snapshotAt;
  final bool manuallyEdited;
  final int version;
  final Map<String, int> events;

  const RefundSourceState({required this.grossCents, this.refundedCents = 0,
    this.basis = 'none', this.snapshotAt, this.manuallyEdited = false,
    this.version = 0, this.events = const {}});

  int get netCents => grossCents - refundedCents;

  RefundSourceState copyWith({int? refundedCents, String? basis,
    DateTime? snapshotAt, Map<String, int>? events}) => RefundSourceState(
      grossCents: grossCents, refundedCents: refundedCents ?? this.refundedCents,
      basis: basis ?? this.basis, snapshotAt: snapshotAt ?? this.snapshotAt,
      manuallyEdited: manuallyEdited, version: version, events: events ?? this.events);
}

class RefundNetDecision {
  final RefundSourceState? state;
  final String? reason;
  final bool duplicate;
  const RefundNetDecision.accept(this.state, {this.duplicate = false}) : reason = null;
  const RefundNetDecision.review(this.reason) : state = null, duplicate = false;
}

/// The pure rules are shared by previews and regression tests.
class RefundNetCalculator {
  static RefundNetDecision cumulative(RefundSourceState current,
      {required int grossCents, required int refundedCents, DateTime? snapshotAt}) {
    if (current.manuallyEdited) return const RefundNetDecision.review('这笔账单已手动调整，请核对实际支出');
    if (grossCents <= 0 || current.grossCents != grossCents) {
      return const RefundNetDecision.review('原付款金额与已保存的订单不一致');
    }
    if (refundedCents < 0 || refundedCents > grossCents) {
      return const RefundNetDecision.review('累计成功退款超过原付款金额');
    }
    if (current.basis == 'events') {
      return const RefundNetDecision.review('此订单已按独立退款记录计算，累计退款列不能重复相加');
    }
    if (refundedCents < current.refundedCents) {
      if (snapshotAt != null && current.snapshotAt != null && snapshotAt.isAfter(current.snapshotAt!)) {
        return const RefundNetDecision.review('较新账单的累计退款反而减少，请核对原始记录');
      }
      // A historical statement must never restore money already refunded.
      return RefundNetDecision.accept(current, duplicate: true);
    }
    if (snapshotAt != null && current.snapshotAt != null &&
        snapshotAt.isBefore(current.snapshotAt!) && refundedCents != current.refundedCents) {
      return const RefundNetDecision.review('较旧账单的退款金额与较新快照不一致');
    }
    final newestSnapshot = current.snapshotAt != null &&
        (snapshotAt == null || snapshotAt.isBefore(current.snapshotAt!))
        ? current.snapshotAt : snapshotAt;
    return RefundNetDecision.accept(current.copyWith(refundedCents: refundedCents,
      basis: 'cumulative', snapshotAt: newestSnapshot),
      duplicate: current.basis == 'cumulative' && refundedCents == current.refundedCents);
  }

  static RefundNetDecision event(RefundSourceState current,
      {required String refundId, required int amountCents}) {
    if (current.manuallyEdited) return const RefundNetDecision.review('这笔账单已手动调整，请核对实际支出');
    if (refundId.isEmpty || amountCents <= 0) return const RefundNetDecision.review('独立退款缺少有效退款单号或金额');
    if (current.basis == 'cumulative' && current.refundedCents > 0) {
      return const RefundNetDecision.review('此订单已有累计退款快照，独立退款记录不能再次扣减');
    }
    final existing = current.events[refundId];
    if (existing != null) {
      return existing == amountCents
          ? RefundNetDecision.accept(current, duplicate: true)
          : const RefundNetDecision.review('同一退款单号出现不同退款金额');
    }
    final events = {...current.events, refundId: amountCents};
    final total = events.values.fold<int>(0, (a, b) => a + b);
    if (total > current.grossCents) return const RefundNetDecision.review('成功退款合计超过原付款金额');
    return RefundNetDecision.accept(current.copyWith(refundedCents: total,
      basis: 'events', events: events));
  }
}

class RefundEvidence {
  final String importKey;
  final String source;
  final int? grossCents;
  final int? cumulativeCents;
  final String? refundId;
  final int? eventCents;
  final DateTime? snapshotAt;
  final DateTime? refundedAt;
  final Map<String, String> original;
  final ExpenseRecord? payment;
  final int rowNumber;

  const RefundEvidence({required this.importKey, required this.source,
    required this.original, required this.rowNumber, this.payment,
    this.grossCents, this.cumulativeCents, this.refundId, this.eventCents,
    this.snapshotAt, this.refundedAt});

  bool get isEvent => refundId != null;
}

class RefundImportPlan {
  final String importKey;
  final ExpenseRecord record;
  final Map<String, Object?>? expectedRecord;
  final Map<String, Object?>? expectedSource;
  final List<Map<String, Object?>> expectedEvents;
  final RefundSourceState state;
  final Map<String, String> original;
  final String source;
  final List<RefundEvidence> eventEvidence;
  const RefundImportPlan({required this.importKey, required this.record,
    required this.expectedRecord, required this.expectedSource,
    required this.expectedEvents, required this.state, required this.original,
    required this.source, this.eventEvidence = const []});
  bool get isNew => expectedRecord == null;
  bool get fullyRefunded => state.netCents == 0;
  static String stableMap(Map<String, Object?>? map) {
    if (map == null) return 'null';
    final keys = map.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: map[key]});
  }
}

class BillImportResult {
  final int inserted;
  final int updated;
  final int fullyRefunded;
  final int queued;
  const BillImportResult({this.inserted = 0, this.updated = 0,
    this.fullyRefunded = 0, this.queued = 0});
}
