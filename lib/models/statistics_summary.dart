import 'expense_record.dart';

enum StatisticsPeriod { week, month, year, custom }

DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime _utcDay(DateTime date) => DateTime.utc(date.year, date.month, date.day);

class StatisticsRange {
  final DateTime start;
  final DateTime end;
  StatisticsRange(DateTime start, DateTime end) : start = _day(start), end = _day(end) {
    if (this.end.isBefore(this.start)) throw ArgumentError('End must follow start');
  }

  factory StatisticsRange.forPeriod(StatisticsPeriod period, DateTime anchor) => switch (period) {
    StatisticsPeriod.week => StatisticsRange(
      DateTime(anchor.year, anchor.month, anchor.day - anchor.weekday + 1),
      DateTime(anchor.year, anchor.month, anchor.day - anchor.weekday + 7)),
    StatisticsPeriod.month => StatisticsRange(DateTime(anchor.year, anchor.month, 1), DateTime(anchor.year, anchor.month + 1, 0)),
    StatisticsPeriod.year => StatisticsRange(DateTime(anchor.year, 1, 1), DateTime(anchor.year, 12, 31)),
    StatisticsPeriod.custom => StatisticsRange(anchor, anchor),
  };

  int get days => _utcDay(end).difference(_utcDay(start)).inDays + 1;
  bool contains(DateTime date) => !_day(date).isBefore(start) && !_day(date).isAfter(end);

  StatisticsRange shift(StatisticsPeriod period, int direction) => switch (period) {
    StatisticsPeriod.week => StatisticsRange.forPeriod(period, DateTime(start.year, start.month, start.day + direction * 7)),
    StatisticsPeriod.month => StatisticsRange.forPeriod(period, DateTime(start.year, start.month + direction, 1)),
    StatisticsPeriod.year => StatisticsRange.forPeriod(period, DateTime(start.year + direction, 1, 1)),
    StatisticsPeriod.custom => StatisticsRange(
      DateTime(start.year, start.month, start.day + direction * days),
      DateTime(end.year, end.month, end.day + direction * days)),
  };
}

class CategoryTotal {
  final int categoryId;
  final int cents;
  final List<ExpenseRecord> records;
  const CategoryTotal(this.categoryId, this.cents, this.records);
  double get amount => cents / 100;
  int get count => records.length;
}

class TrendPoint {
  final DateTime date;
  int expenseCents = 0;
  int incomeCents = 0;
  TrendPoint(this.date);
  double get expense => expenseCents / 100;
  double get income => incomeCents / 100;
}

class StatisticsSummary {
  final StatisticsRange range;
  final List<ExpenseRecord> records;
  late final int expenseCents;
  late final int incomeCents;

  StatisticsSummary(this.range, Iterable<ExpenseRecord> input)
      : records = input.where((r) => range.contains(r.date)).toList() {
    records.sort((a, b) => b.date.compareTo(a.date));
    expenseCents = _sum('expense');
    incomeCents = _sum('income');
  }

  int _sum(String type) => records.where((r) => r.type == type).fold(0, (total, r) => total + (r.amount * 100).round());
  double get expense => expenseCents / 100;
  double get income => incomeCents / 100;
  double get balance => (incomeCents - expenseCents) / 100;
  double get dailyExpense => expense / range.days;
  int get expenseCount => records.where((r) => r.type == 'expense').length;
  int get incomeCount => records.where((r) => r.type == 'income').length;
  double get largestExpense => records.where((r) => r.type == 'expense')
    .fold<double>(0, (largest, r) => r.amount > largest ? r.amount : largest);

  List<CategoryTotal> categories(String type) {
    final grouped = <int, List<ExpenseRecord>>{};
    for (final record in records.where((r) => r.type == type)) {
      grouped.putIfAbsent(record.categoryId, () => []).add(record);
    }
    final totals = grouped.entries.map((entry) => CategoryTotal(entry.key,
      entry.value.fold<int>(0, (sum, r) => sum + (r.amount * 100).round()),
      List.unmodifiable(entry.value))).toList();
    totals.sort((a, b) {
      final amountOrder = b.cents.compareTo(a.cents);
      return amountOrder != 0 ? amountOrder : a.categoryId.compareTo(b.categoryId);
    });
    return totals;
  }

  // Long ranges aggregate by month/year; short ranges include every day, including zero days.
  String get trendUnit => range.days > 730 ? 'year' : range.days > 62 ? 'month' : 'day';

  List<TrendPoint> trend() {
    final unit = trendUnit;
    DateTime bucket(DateTime date) => unit == 'year' ? DateTime(date.year)
      : unit == 'month' ? DateTime(date.year, date.month) : _day(date);
    DateTime next(DateTime date) => unit == 'year' ? DateTime(date.year + 1)
      : unit == 'month' ? DateTime(date.year, date.month + 1) : DateTime(date.year, date.month, date.day + 1);
    final points = <DateTime, TrendPoint>{};
    for (var cursor = bucket(range.start); !cursor.isAfter(range.end); cursor = next(cursor)) {
      points[cursor] = TrendPoint(cursor);
    }
    for (final record in records) {
      final point = points[bucket(record.date)]!;
      final cents = (record.amount * 100).round();
      if (record.type == 'expense') point.expenseCents += cents;
      if (record.type == 'income') point.incomeCents += cents;
    }
    return points.values.toList();
  }
}
