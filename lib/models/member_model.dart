import 'package:cloud_firestore/cloud_firestore.dart';

class MemberModel {
  final String id;
  final String firstName;
  final String lastName;
  final String email;
  final String? phoneNumber;
  final String? address;
  final DateTime? dob;
  final bool isVisitor;
  final List<String> ministries; // Membership
  final List<String> leadershipMinistries; // Ministries where the user is leader
  final List<String> roles; // 🆕 Roles like ['member', 'leader']
  final String? userId; // 🆕 Direct link to Firebase User ID
  final Timestamp createdAt;

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
    required this.roles, // 🆕
    this.userId, // 🆕
    required this.createdAt,
  });

  factory MemberModel.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MemberModel(
      id: doc.id,
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      email: data['email'] ?? '',
      phoneNumber: data['phoneNumber'],
      address: data['address'],
      dob: data['dateOfBirth'] is Timestamp
          ? (data['dateOfBirth'] as Timestamp).toDate()
          : (data['dob'] is Timestamp ? (data['dob'] as Timestamp).toDate() : null),
      isVisitor: data['isVisitor'] ?? false,
      ministries: List<String>.from(data['ministries'] ?? []),
      leadershipMinistries: List<String>.from(data['leadershipMinistries'] ?? []),
      roles: List<String>.from(data['roles'] ?? ['member']), // 🆕
      userId: data['userUid'] ?? data['userId'], // 🆕
      createdAt: data['createdAt'] ?? Timestamp.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'phoneNumber': phoneNumber,
      'address': address,
      'dateOfBirth': dob != null ? Timestamp.fromDate(dob!) : null,
      'isVisitor': isVisitor,
      'ministries': ministries,
      'leadershipMinistries': leadershipMinistries,
      'roles': roles, // 🆕
      'userUid': userId, // 🆕
      'createdAt': createdAt,
    };
  }
}
