class Ledger {
  int? id;
  String name;
  String? icon; // 图标代码或路径
  int isDefault; // 0: 否, 1: 是（总账本）
  String? desc;
  // 为同步预留
  String? cloudId;
  int? userId;

  Ledger({
    this.id,
    required this.name,
    this.icon,
    this.isDefault = 0,
    this.desc,
    this.cloudId,
    this.userId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
      'is_default': isDefault,
      'desc': desc,
      'cloud_id': cloudId,
      'user_id': userId,
    };
  }

  factory Ledger.fromMap(Map<String, dynamic> map) {
    return Ledger(
      id: map['id'],
      name: map['name'],
      icon: map['icon'],
      isDefault: map['is_default'],
      desc: map['desc'],
      cloudId: map['cloud_id'],
      userId: map['user_id'],
    );
  }
}