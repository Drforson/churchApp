import 'package:cloud_firestore/cloud_firestore.dart';

/// App-wide role enum in ascending authority
/// (adjust order if you change precedence)
enum UserRole { member, usher, leader, pastor, admin }

extension UserRoleX on UserRole {
  String get asString {
    switch (this) {
      case UserRole.member:
        return 'member';
      case UserRole.usher:
        return 'usher';
      case UserRole.leader:
        return 'leader';
      case UserRole.pastor:
        return 'pastor';
      case UserRole.admin:
        return 'admin';
    }
  }

  static UserRole fromString(String? value) {
    switch ((value ?? '').toLowerCase().trim()) {
      case 'admin':
        return UserRole.admin;
      case 'pastor':
        return UserRole.pastor;
      case 'leader':
        return UserRole.leader;
      case 'usher':
        return UserRole.usher;
      default:
        return UserRole.member;
    }
  }
}

/// In case you still have legacy users with an array `roles: []`,
/// pick the highest role from that array. Otherwise default to member.
UserRole _highestFromLegacyRoles(List<dynamic>? roles) {
  if (roles == null || roles.isEmpty) return UserRole.member;
  final set = roles.map((e) => (e ?? '').toString().toLowerCase().trim()).toSet();

  // Precedence: admin > pastor > leader > usher > member
  if (set.contains('admin')) return UserRole.admin;
  if (set.contains('pastor')) return UserRole.pastor;
  if (set.contains('leader')) return UserRole.leader;
  if (set.contains('usher')) return UserRole.usher;
  return UserRole.member;
}

class UserModel {
  final String uid;
  final String email;
  /// Single-value role used for routing/views
  final UserRole role;
  /// Keep ministry leadership by NAMEs (optional helper for UI)
  final List<String> leadershipMinistries;
  /// Link to members/{memberId}
  final String? memberId;
  final Timestamp createdAt;
  final Timestamp? updatedAt;

  const UserModel({
    required this.uid,
    required this.email,
    required this.role,
    required this.leadershipMinistries,
    this.memberId,
    required this.createdAt,
    this.updatedAt,
  });

  /// Robust fromDocument that:
  /// - prefers `role` (string)
  /// - falls back to legacy `roles` (array) and chooses the highest
  factory UserModel.fromDocument(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};

    // Prefer new single 'role' field; else derive from legacy 'roles' array.
    final roleStr = (data['role'] as String?);
    final legacyRoles = (data['roles'] is List) ? (data['roles'] as List) : const [];
    final role = roleStr != null
        ? UserRoleX.fromString(roleStr)
        : _highestFromLegacyRoles(legacyRoles);

    // leadershipMinistries may be absent or non-list; normalize safely
    final lmRaw = data['leadershipMinistries'];
    final leadershipMinistries = (lmRaw is List)
        ? lmRaw.map((e) => (e ?? '').toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final createdAt = (data['createdAt'] is Timestamp)
        ? data['createdAt'] as Timestamp
        : Timestamp.now();

    final updatedAt = (data['updatedAt'] is Timestamp) ? data['updatedAt'] as Timestamp : null;

    return UserModel(
      uid: doc.id,
      email: (data['email'] as String? ?? '').trim().toLowerCase(),
      role: role,
      leadershipMinistries: leadershipMinistries,
      memberId: data['memberId'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Serialize to Firestore using the new schema:
  /// - `role` as a single lowercase string
  /// - includes `leadershipMinistries`, `memberId`, timestamps
  Map<String, dynamic> toMap({bool includeTimestamps = true}) {
    final map = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'role': role.asString,
      'leadershipMinistries': leadershipMinistries,
      'memberId': memberId,
    };
    if (includeTimestamps) {
      map['createdAt'] = createdAt;
      if (updatedAt != null) map['updatedAt'] = updatedAt;
    }
    return map;
  }

  UserModel copyWith({
    String? uid,
    String? email,
    UserRole? role,
    List<String>? leadershipMinistries,
    String? memberId,
    Timestamp? createdAt,
    Timestamp? updatedAt,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      role: role ?? this.role,
      leadershipMinistries: leadershipMinistries ?? this.leadershipMinistries,
      memberId: memberId ?? this.memberId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // Convenience booleans for UI gating
  bool get isAdmin  => role == UserRole.admin;
  bool get isPastor => role == UserRole.pastor;
  bool get isLeader => role == UserRole.leader;
  bool get isUsher  => role == UserRole.usher;
  bool get isMember => role == UserRole.member;
}
