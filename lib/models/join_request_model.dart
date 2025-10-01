import 'package:cloud_firestore/cloud_firestore.dart';

class JoinRequestModel {
  final String id;
  final String memberId;     // <-- member doc id (NOT auth uid)
  final String ministryId;   // <-- ministry NAME per your rules (or switch to id if you migrate)
  final String status;       // 'pending' | 'approved' | 'rejected'
  final Timestamp requestedAt;
  final Timestamp? updatedAt;

  JoinRequestModel({
    required this.id,
    required this.memberId,
    required this.ministryId,
    required this.status,
    required this.requestedAt,
    this.updatedAt,
  });

  factory JoinRequestModel.fromDocument(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>? ?? {});
    // Backward compatibility: accept 'timestamp' when 'requestedAt' is missing
    final Timestamp requested =
        (data['requestedAt'] as Timestamp?) ??
            (data['timestamp'] as Timestamp?) ??
            Timestamp.now();

    return JoinRequestModel(
      id: doc.id,
      memberId: (data['memberId'] ?? '').toString(),
      ministryId: (data['ministryId'] ?? '').toString(),
      status: (data['status'] ?? 'pending').toString(),
      requestedAt: requested,
      updatedAt: data['updatedAt'] as Timestamp?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'memberId': memberId,
      'ministryId': ministryId,
      'status': status,
      'requestedAt': requestedAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }
}
