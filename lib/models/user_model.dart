// lib/models/user_and_member_models.dart
import 'package:cloud_firestore/cloud_firestore.dart';

/// App-wide role enum in ascending authority (used for routing/UI gates).
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

/* ---------------- Shared helpers ---------------- */

List<String> normalizeRoleList(Iterable<dynamic>? roles) {
  if (roles == null) return const [];
  final out = <String>[];
  for (final r in roles) {
    final s = (r ?? '').toString().trim().toLowerCase();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

UserRole highestFromLegacyRoles(List<dynamic>? roles) {
  final set = normalizeRoleList(roles).toSet();
  if (set.contains('admin')) return UserRole.admin;
  if (set.contains('pastor')) return UserRole.pastor;
  if (set.contains('leader')) return UserRole.leader;
  if (set.contains('usher')) return UserRole.usher;
  return UserRole.member;
}

String _safeLower(String? s) => (s ?? '').trim().toLowerCase();
String _joinName(String a, String b) => [a, b].where((e) => e.trim().isNotEmpty).join(' ').trim();

/* ---------------- User Model (users/{uid}) ---------------- */

class UserModel {
  final String uid;
  final String email; // stored lowercase
  /// Single-value role used for routing/views (source of truth on user)
  final UserRole role;
  /// Optional legacy mirror; we still read it but don't need to write it.
  final List<String> rolesLegacyLower;
  /// Names of ministries where the user is a leader (by NAME)
  final List<String> leadershipMinistries;
  /// Link to members/{memberId} (bidirectional with MemberModel.userId)
  final String? memberId;
  final Timestamp? createdAt;
  final Timestamp? updatedAt;

  const UserModel({
    required this.uid,
    required this.email,
    required this.role,
    required this.rolesLegacyLower,
    required this.leadershipMinistries,
    required this.memberId,
    this.createdAt,
    this.updatedAt,
  });

  factory UserModel.fromDocument(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};

    final roleStr = data['role'] as String?;
    final legacyRoles = (data['roles'] is List) ? (data['roles'] as List) : const [];
    final resolvedRole = roleStr != null && roleStr is String && roleStr.trim().isNotEmpty
        ? UserRoleX.fromString(roleStr)
        : highestFromLegacyRoles(legacyRoles);

    final lmRaw = data['leadershipMinistries'];
    final lm = (lmRaw is List)
        ? lmRaw.map((e) => (e ?? '').toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return UserModel(
      uid: doc.id,
      email: _safeLower(data['email'] as String?),
      role: resolvedRole,
      rolesLegacyLower: normalizeRoleList(legacyRoles),
      leadershipMinistries: lm,
      memberId: (data['memberId'] as String?)?.trim().isNotEmpty == true ? data['memberId'] as String : null,
      createdAt: data['createdAt'] is Timestamp ? data['createdAt'] as Timestamp : null,
      updatedAt: data['updatedAt'] is Timestamp ? data['updatedAt'] as Timestamp : null,
    );
  }

  Map<String, dynamic> toMap({bool includeTimestamps = true}) {
    final map = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'role': role.asString, // single-source-of-truth for UI/rules
      'leadershipMinistries': leadershipMinistries,
      'memberId': memberId,
    };
    if (includeTimestamps) {
      if (createdAt != null) map['createdAt'] = createdAt;
      if (updatedAt != null) map['updatedAt'] = updatedAt;
    }
    // remove nulls
    map.removeWhere((k, v) => v == null);
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
    List<String>? rolesLegacyLower,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      role: role ?? this.role,
      leadershipMinistries: leadershipMinistries ?? this.leadershipMinistries,
      memberId: memberId ?? this.memberId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rolesLegacyLower: rolesLegacyLower ?? this.rolesLegacyLower,
    );
  }

  // Convenience gates for UI
  bool get isAdmin  => role == UserRole.admin;
  bool get isPastor => role == UserRole.pastor;
  bool get isLeader => role == UserRole.leader;
  bool get isUsher  => role == UserRole.usher;
  bool get isMember => role == UserRole.member;

  /* withConverter helper */
  static CollectionReference<UserModel> col(FirebaseFirestore db) =>
      db.collection('users').withConverter<UserModel>(
        fromFirestore: (snap, _) => UserModel.fromDocument(snap),
        toFirestore: (u, _) => u.toMap(includeTimestamps: true),
      );
}

/* ---------------- Member Model (members/{memberId}) ---------------- */

class MemberModel {
  final String id;
  final String firstName;
  final String lastName;
  final String email; // stored lowercase for searches
  final String? phoneNumber;
  final String? address;
  final DateTime? dob;
  final bool isVisitor;

  /// Membership by NAME
  final List<String> ministries;

  /// Ministries where the person is a leader (by NAME)
  final List<String> leadershipMinistries;

  /// Roles on the member (lowercase strings, e.g. ['member','leader','admin'])
  /// Functions keep this normalized to lowercase.
  final List<String> roles;

  /// Direct link to Firebase Auth user UID
  final String? userId;

  /// Denormalized for search
  final String fullName;
  final String fullNameLower;

  final Timestamp? createdAt;
  final Timestamp? updatedAt;

  MemberModel({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phoneNumber,
    this.address,
    this.dob,
    required this.isVisitor,
    required this.ministries,
    required this.leadershipMinistries,
    required this.roles,
    required this.userId,
    required this.fullName,
    required this.fullNameLower,
    this.createdAt,
    this.updatedAt,
  });

  factory MemberModel.fromDocument(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};

    final first = (data['firstName'] as String? ?? '').trim();
    final last  = (data['lastName']  as String? ?? '').trim();
    final full  = (data['fullName']  as String? ?? '').trim();
    final computedFull = _joinName(first, last);
    final finalFull = computedFull.isNotEmpty ? computedFull : full;
    final finalFullLower = finalFull.toLowerCase();

    return MemberModel(
      id: doc.id,
      firstName: first,
      lastName: last,
      email: _safeLower(data['email'] as String?),
      phoneNumber: (data['phoneNumber'] as String?)?.trim(),
      address: (data['address'] as String?)?.trim(),
      dob: data['dob'] is Timestamp ? (data['dob'] as Timestamp).toDate() : null,
      isVisitor: (data['isVisitor'] as bool?) ?? false,
      ministries: (data['ministries'] is List)
          ? List<String>.from((data['ministries'] as List).map((e) => (e ?? '').toString()))
          : <String>[],
      leadershipMinistries: (data['leadershipMinistries'] is List)
          ? List<String>.from((data['leadershipMinistries'] as List).map((e) => (e ?? '').toString()))
          : <String>[],
      roles: normalizeRoleList(data['roles'] as List? ?? const []),
      userId: (data['userId'] as String?)?.trim(),
      fullName: finalFull,
      fullNameLower: (data['fullNameLower'] as String? ?? finalFullLower),
      createdAt: data['createdAt'] is Timestamp ? data['createdAt'] as Timestamp : null,
      updatedAt: data['updatedAt'] is Timestamp ? data['updatedAt'] as Timestamp : null,
    );
  }

  Map<String, dynamic> toMap({bool includeTimestamps = true}) {
    final map = <String, dynamic>{
      'firstName': firstName,
      'lastName': lastName,
      'fullName': fullName.isNotEmpty ? fullName : _joinName(firstName, lastName),
      'fullNameLower': fullNameLower.isNotEmpty
          ? fullNameLower
          : _joinName(firstName, lastName).toLowerCase(),
      'email': email.trim().toLowerCase(),
      'phoneNumber': phoneNumber,
      'address': address,
      'dob': dob != null ? Timestamp.fromDate(dob!) : null,
      'isVisitor': isVisitor,
      'ministries': ministries,
      'leadershipMinistries': leadershipMinistries,
      'roles': roles.map((e) => e.toLowerCase()).toList(),
      'userId': userId,
    };
    if (includeTimestamps) {
      if (createdAt != null) map['createdAt'] = createdAt;
      if (updatedAt != null) map['updatedAt'] = updatedAt;
    }
    map.removeWhere((k, v) => v == null);
    return map;
  }

  MemberModel copyWith({
    String? id,
    String? firstName,
    String? lastName,
    String? email,
    String? phoneNumber,
    String? address,
    DateTime? dob,
    bool? isVisitor,
    List<String>? ministries,
    List<String>? leadershipMinistries,
    List<String>? roles,
    String? userId,
    String? fullName,
    String? fullNameLower,
    Timestamp? createdAt,
    Timestamp? updatedAt,
  }) {
    final nextFull = fullName ?? this.fullName;
    return MemberModel(
      id: id ?? this.id,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      address: address ?? this.address,
      dob: dob ?? this.dob,
      isVisitor: isVisitor ?? this.isVisitor,
      ministries: ministries ?? this.ministries,
      leadershipMinistries: leadershipMinistries ?? this.leadershipMinistries,
      roles: roles != null ? normalizeRoleList(roles) : this.roles,
      userId: userId ?? this.userId,
      fullName: nextFull,
      fullNameLower: fullNameLower ?? nextFull.toLowerCase(),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // Convenience gates for UI (derived from member roles/leadership)
  bool get isAdmin  => roles.contains('admin');
  bool get isPastor => roles.contains('pastor');
  bool get isLeader => roles.contains('leader') || leadershipMinistries.isNotEmpty;
  bool get isUsher  => roles.contains('usher');

  /* withConverter helper */
  static CollectionReference<MemberModel> col(FirebaseFirestore db) =>
      db.collection('members').withConverter<MemberModel>(
        fromFirestore: (snap, _) => MemberModel.fromDocument(snap),
        toFirestore: (m, _) => m.toMap(includeTimestamps: true),
      );
}
