class Budget {
  int? id;
  int ledgerId;
  int? categoryId; // 为null表示整个账本的总预算
  double amount;
  String cycle; // 'month'(月), 'week'(周), 'custom'(自定义)
  DateTime startDate;
  DateTime endDate;
  // 为同步预留
  String? cloudId;
  int? userId;

  Budget({
    this.id,
    required this.ledgerId,
    this.categoryId,
    required this.amount,
    required this.cycle,
    required this.startDate,
    required this.endDate,
    this.cloudId,
    this.userId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'ledger_id': ledgerId,
      'category_id': categoryId,
      'amount': amount,
      'cycle': cycle,
      'start_date': startDate.toIso8601String(),
      'end_date': endDate.toIso8601String(),
      'cloud_id': cloudId,
      'user_id': userId,
    };
  }

  factory Budget.fromMap(Map<String, dynamic> map) {
    return Budget(
      id: map['id'],
      ledgerId: map['ledger_id'],
      categoryId: map['category_id'],
      amount: map['amount'],
      cycle: map['cycle'],
      startDate: DateTime.parse(map['start_date']),
      endDate: DateTime.parse(map['end_date']),
      cloudId: map['cloud_id'],
      userId: map['user_id'],
    );
  }
}