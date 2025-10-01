import 'package:cloud_firestore/cloud_firestore.dart';

class MemberService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> promoteToLeader(String memberId, String ministryId) async {
    final docRef = _db.collection('members').doc(memberId);
    final snapshot = await docRef.get();
    if (!snapshot.exists) return;

    final data = snapshot.data()!;
    final currentLeaderships = List<String>.from(data['ministryLeaderships'] ?? []);
    if (!currentLeaderships.contains(ministryId)) {
      currentLeaderships.add(ministryId);
    }

    final newRole = currentLeaderships.isEmpty ? 'member' : 'leader';

    await docRef.update({
      'ministryLeaderships': currentLeaderships,
      'userRole': newRole,
    });

    // Also update user role in users collection
    await _db.collection('users').doc(memberId).update({'userRole': newRole});
  }

  Future<void> demoteFromLeader(String memberId, String ministryId) async {
    final docRef = _db.collection('members').doc(memberId);
    final snapshot = await docRef.get();
    if (!snapshot.exists) return;

    final data = snapshot.data()!;
    final currentLeaderships = List<String>.from(data['ministryLeaderships'] ?? []);
    currentLeaderships.remove(ministryId);

    final newRole = currentLeaderships.isEmpty ? 'member' : 'leader';

    await docRef.update({
      'ministryLeaderships': currentLeaderships,
      'userRole': newRole,
    });

    // Also update user role in users collection
    await _db.collection('users').doc(memberId).update({'userRole': newRole});
  }

  Future<void> syncUserRoleFromLeaderships(String memberId) async {
    final snapshot = await _db.collection('members').doc(memberId).get();
    if (!snapshot.exists) return;

    final leaderships = List<String>.from(snapshot.data()?['ministryLeaderships'] ?? []);
    final newRole = leaderships.isEmpty ? 'member' : 'leader';

    await _db.collection('members').doc(memberId).update({'userRole': newRole});
    await _db.collection('users').doc(memberId).update({'userRole': newRole});
  }
}
