class ExpenseRecord {
  int? id;
  int ledgerId; // 所属账本
  String type; // 'expense' or 'income'
  double amount;
  int categoryId;
  int? assetAccountId; // 关联的资产账户（如从哪个银行卡支付）
  DateTime date;
  String? note;
  String? title;
  // 为同步预留
  String? cloudId;
  String? importKey;
  int? refundGrossCents;
  int? refundTotalCents;
  String? refundBasis;
  int? userId;
  int isSynced; // 0: 未同步, 1: 已同步

  ExpenseRecord({
    this.id,
    required this.ledgerId,
    required this.type,
    required this.amount,
    required this.categoryId,
    this.assetAccountId,
    required this.date,
    this.note,
    this.title,
    this.cloudId,
    this.importKey,
    this.refundGrossCents,
    this.refundTotalCents,
    this.refundBasis,
    this.userId,
    this.isSynced = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'ledger_id': ledgerId,
      'type': type,
      'amount': amount,
      'category_id': categoryId,
      'asset_account_id': assetAccountId,
      'date': date.toIso8601String(),
      'note': note,
      'title': title,
      'cloud_id': cloudId,
      'import_key': importKey,
      'refund_gross_cents': refundGrossCents,
      'refund_total_cents': refundTotalCents,
      'refund_basis': refundBasis,
      'user_id': userId,
      'is_synced': isSynced,
    };
  }

  factory ExpenseRecord.fromMap(Map<String, dynamic> map) {
    return ExpenseRecord(
      id: map['id'],
      ledgerId: map['ledger_id'],
      type: map['type'],
      amount: (map['amount'] as num).toDouble(),
      categoryId: map['category_id'],
      assetAccountId: map['asset_account_id'],
      date: DateTime.parse(map['date']),
      note: map['note'],
      title: map['title'],
      cloudId: map['cloud_id'],
      importKey: map['import_key'],
      refundGrossCents: map['refund_gross_cents'],
      refundTotalCents: map['refund_total_cents'],
      refundBasis: map['refund_basis'],
      userId: map['user_id'],
      isSynced: map['is_synced'] ?? 0,
    );
  }

  String displayTitle(String? categoryName) {
    final name = title?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final category = categoryName?.trim() ?? '';
    return category.isNotEmpty ? category : (type == 'income' ? '收入' : '支出');
  }

  @override
  String toString() {
    return '账单#$id: $type ￥$amount ($note)';
  }
}
