class User {
  int? id;
  String username;
  String? email;
  String? avatarPath;
  String? localPasswordHash;
  String? cloudUid;
  DateTime? createdAt;

  User({
    this.id,
    required this.username,
    this.email,
    this.avatarPath,
    this.localPasswordHash,
    this.cloudUid,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'avatar_path': avatarPath,
      'local_password_hash': localPasswordHash,
      'cloud_uid': cloudUid,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'],
      username: map['username'],
      email: map['email'],
      avatarPath: map['avatar_path'],
      localPasswordHash: map['local_password_hash'],
      cloudUid: map['cloud_uid'],
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'])
          : null,
    );
  }

  @override
  String toString() {
    return '用户#$id: $username';
  }
}
