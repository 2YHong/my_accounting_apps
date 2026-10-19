class AssetAccount {
  int? id;
  String name;
  String
  type; // 'cash'(现金), 'bank'(银行卡), 'loan'(借贷账户), 'investment'(投资), 'digital'(支付宝/微信), 'custom'(自定义)
  String? icon;
  double balance;
  double? storedBalance;
  int? balanceOffsetCents;
  String? cardNumberLastFour; // 卡号末四位
  double? creditLimit; // 信用额度（借贷账户用）
  // 注意：对于借贷账户，balance 表示已借款金额，creditLimit 表示总贷款额度
  String? desc;
  int? categoryId; // 关联自定义账户的子分类
  int? userId;

  AssetAccount({
    this.id,
    required this.name,
    required this.type,
    this.icon,
    required this.balance,
    this.storedBalance,
    this.balanceOffsetCents,
    this.cardNumberLastFour,
    this.creditLimit,
    this.desc,
    this.categoryId,
    this.userId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'icon': icon,
      'balance': storedBalance ?? balance,
      'balance_offset_cents': balanceOffsetCents,
      'card_number_last_four': cardNumberLastFour,
      'credit_limit': creditLimit,
      'desc': desc,
      'category_id': categoryId,
      'user_id': userId,
    };
  }

  factory AssetAccount.fromMap(Map<String, dynamic> map) {
    return AssetAccount(
      id: map['id'],
      name: map['name'],
      type: map['type'],
      icon: map['icon'],
      balance: map['current_balance_cents'] is num
          ? (map['current_balance_cents'] as num).toInt() / 100
          : (map['balance'] as num).toDouble(),
      storedBalance: (map['balance'] as num).toDouble(),
      balanceOffsetCents: map['balance_offset_cents'] as int?,
      cardNumberLastFour: map['card_number_last_four'],
      creditLimit: (map['credit_limit'] as num?)?.toDouble(),
      desc: map['desc'],
      categoryId: map['category_id'],
      userId: map['user_id'],
    );
  }
}
