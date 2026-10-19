import 'dart:convert';

class RecurringBill {
  final int? id;
  final int? userId;
  final String title;
  final String type;
  final int amountCents;
  final int ledgerId;
  final int categoryId;
  final int? assetAccountId;
  final int dayOfMonth;
  final DateTime startDate;
  final DateTime activeFrom;
  final bool enabled;
  final String? note;
  final DateTime? deletedAt;

  const RecurringBill({this.id, this.userId, required this.title,
    required this.type, required this.amountCents, required this.ledgerId,
    required this.categoryId, this.assetAccountId, required this.dayOfMonth,
    required this.startDate, required this.activeFrom, this.enabled = true,
    this.note, this.deletedAt});

  double get amount => amountCents / 100;
  String get amountText => '${amountCents ~/ 100}.${(amountCents % 100).toString().padLeft(2, '0')}';

  static DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

  static DateTime dueDate(int year, int month, int dayOfMonth) {
    if (dayOfMonth < 1 || dayOfMonth > 31) throw ArgumentError.value(dayOfMonth, 'dayOfMonth');
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, dayOfMonth > lastDay ? lastDay : dayOfMonth);
  }

  static String periodFor(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}';

  /// Dates are calendar days; daylight saving changes do not shift a due date.
  Iterable<DateTime> datesBetween(DateTime first, DateTime last,
    {Set<String> excludedPeriods = const {}}) sync* {
    if (!enabled || deletedAt != null) return;
    var lower = dateOnly(first);
    if (dateOnly(startDate).isAfter(lower)) lower = dateOnly(startDate);
    if (dateOnly(activeFrom).isAfter(lower)) lower = dateOnly(activeFrom);
    final upper = dateOnly(last);
    if (lower.isAfter(upper)) return;
    var month = DateTime(lower.year, lower.month);
    while (!month.isAfter(upper)) {
      final date = dueDate(month.year, month.month, dayOfMonth);
      if (!date.isBefore(lower) && !date.isAfter(upper) &&
        !excludedPeriods.contains(periodFor(date))) yield date;
      month = DateTime(month.year, month.month + 1);
    }
  }

  Map<String, Object?> toMap() => {
    'id': id, 'user_id': userId, 'title': title, 'type': type,
    'amount_cents': amountCents, 'ledger_id': ledgerId,
    'category_id': categoryId, 'asset_account_id': assetAccountId,
    'day_of_month': dayOfMonth, 'start_date': dateOnly(startDate).toIso8601String(),
    'active_from': dateOnly(activeFrom).toIso8601String(), 'enabled': enabled ? 1 : 0,
    'note': note, 'deleted_at': deletedAt?.toIso8601String(),
  };

  factory RecurringBill.fromMap(Map<String, dynamic> map) => RecurringBill(
    id: map['id'] as int?, userId: map['user_id'] as int?,
    title: map['title'] as String, type: map['type'] as String,
    amountCents: map['amount_cents'] as int, ledgerId: map['ledger_id'] as int,
    categoryId: map['category_id'] as int, assetAccountId: map['asset_account_id'] as int?,
    dayOfMonth: map['day_of_month'] as int,
    startDate: DateTime.parse(map['start_date'] as String),
    activeFrom: DateTime.parse(map['active_from'] as String),
    enabled: map['enabled'] == 1, note: map['note'] as String?,
    deletedAt: map['deleted_at'] == null ? null : DateTime.parse(map['deleted_at'] as String));

  static int? parseAmountCents(String text) {
    final match = RegExp(r'^(\d{1,10})(?:\.(\d{1,2}))?$').firstMatch(text.trim());
    if (match == null) return null;
    final cents = int.parse(match[1]!) * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
    return cents > 0 ? cents : null;
  }
}

class RecurringOccurrence {
  final int id;
  final int ruleId;
  final int userId;
  final String period;
  final DateTime dueDate;
  final RecurringBill snapshot;
  final String status;
  final int? recordId;

  const RecurringOccurrence({required this.id, required this.ruleId,
    required this.userId, required this.period, required this.dueDate,
    required this.snapshot, required this.status, this.recordId});

  factory RecurringOccurrence.fromMap(Map<String, dynamic> map) => RecurringOccurrence(
    id: map['id'] as int, ruleId: map['rule_id'] as int, userId: map['user_id'] as int,
    period: map['period'] as String, dueDate: DateTime.parse(map['due_date'] as String),
    snapshot: RecurringBill.fromMap(Map<String, dynamic>.from(jsonDecode(map['snapshot'] as String) as Map)),
    status: map['status'] as String, recordId: map['record_id'] as int?);
}
