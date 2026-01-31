import 'package:cloud_firestore/cloud_firestore.dart';

class MinistryService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Checks if the user is a leader of the specified ministry.
  Future<bool> isLeaderOf(String userId, String ministryId) async {
    final snapshot = await _db.collection('members').doc(userId).get();
    if (!snapshot.exists) return false;

    final data = snapshot.data();
    final List<dynamic> leaderships = data?['leadershipMinistries'] ?? [];
    return leaderships.contains(ministryId);
  }

  /// Approves a join request and adds the member to the ministry.
  /// Only admins or leaders of the ministry can approve.
  Future<void> approveJoinRequest(
      String requestId,
      String ministryId,
      String memberId,
      String approverId,
      ) async {
    final isLeader = await isLeaderOf(approverId, ministryId);
    final isAdmin = await _isAdmin(approverId);

    if (!isLeader && !isAdmin) {
      throw Exception("Not authorized to approve this request.");
    }

    // Add the member to the ministry
    final memberRef = _db.collection('members').doc(memberId);
    final userData = await memberRef.get();
    if (!userData.exists) return;

    final ministries = List<String>.from(userData.data()?['ministries'] ?? []);
    if (!ministries.contains(ministryId)) {
      ministries.add(ministryId);
    }

    await memberRef.update({'ministries': ministries});

    // Mark the join request as approved
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'approved',
      'approvedBy': approverId,
      'approvedAt': Timestamp.now(),
    });
  }

  /// Rejects a join request.
  Future<void> rejectJoinRequest(String requestId, String approverId) async {
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'rejected',
      'approvedBy': approverId,
      'approvedAt': Timestamp.now(),
    });
  }

  /// Internal: Checks if the user has an admin role.
  Future<bool> _isAdmin(String userId) async {
    final snapshot = await _db.collection('users').doc(userId).get();
    if (!snapshot.exists) return false;

    final data = snapshot.data() ?? {};
    final single = (data['role'] ?? '').toString().toLowerCase().trim();
    if (single == 'admin') return true;
    final roles = (data['roles'] is List)
        ? List<String>.from((data['roles'] as List).map((e) => e.toString().toLowerCase()))
        : const <String>[];
    return roles.contains('admin');
  }
}
