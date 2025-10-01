import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String email;
  final List<String> roles; // e.g., ['admin', 'leader', 'member']
  final List<String> leadershipMinistries; // New: track ministries where user is leader
  final String? memberId; // Link to Member document
  final Timestamp createdAt;

  UserModel({
    required this.uid,
    required this.email,
    required this.roles,
    required this.leadershipMinistries,
    this.memberId,
    required this.createdAt,
  });

  factory UserModel.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserModel(
      uid: doc.id,
      email: data['email'] ?? '',
      roles: List<String>.from(data['roles'] ?? ['member']),
      leadershipMinistries: List<String>.from(data['leadershipMinistries'] ?? []), // 🆕
      memberId: data['memberId'],
      createdAt: data['createdAt'] ?? Timestamp.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'roles': roles,
      'leadershipMinistries': leadershipMinistries, // 🆕
      'memberId': memberId,
      'createdAt': createdAt,
    };
  }
}
