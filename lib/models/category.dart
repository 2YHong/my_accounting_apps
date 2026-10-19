class Category {
  int? id;
  String name;
  String type; // 'expense', 'income', 'ignore'
  String? icon;
  int isSystem; // 0: 自定义, 1: 系统内置
  int? parentId;
  int? userId;
  String? color; // 新增：分类颜色

  Category({
    this.id,
    required this.name,
    required this.type,
    this.icon,
    this.isSystem = 0,
    this.parentId,
    this.userId,
    this.color,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'icon': icon,
      'is_system': isSystem,
      'parent_id': parentId,
      'user_id': userId,
      'color': color,
    };
  }

  factory Category.fromMap(Map<String, dynamic> map) {
    return Category(
      id: map['id'],
      name: map['name'],
      type: map['type'],
      icon: map['icon'],
      isSystem: map['is_system'] ?? 0,
      parentId: map['parent_id'],
      userId: map['user_id'],
      color: map['color'],
    );
  }

  @override
  String toString() {
    return '分类#$id: $name ($type)';
  }
}