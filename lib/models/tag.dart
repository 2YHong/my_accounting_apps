class Tag {
  int? id;
  String name;
  String? color;
  int? userId;

  Tag({
    this.id,
    required this.name,
    this.color,
    this.userId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'color': color,
      'user_id': userId,
    };
  }

  factory Tag.fromMap(Map<String, dynamic> map) {
    return Tag(
      id: map['id'],
      name: map['name'],
      color: map['color'],
      userId: map['user_id'],
    );
  }

  @override
  String toString() {
    return '标签#$id: $name';
  }
}