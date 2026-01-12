import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Service for admin/leader actions on members:
/// - Promote/demote to leader for a ministry
/// - Remove member from a ministry
/// - Bulk role management (via Cloud Functions)
///
/// IMPORTANT:
/// - `memberId` is the ID of documents in `members/{memberId}`
/// - User docs live in `users/{uid}` and are linked via `users.memberId` or `members.userUid`
/// - We DO NOT directly write `roles` / `role` on users here; that is handled
///   by your Cloud Functions (`setMemberRoles`, `onMemberRolesChanged`, etc.).
class MemberService {
  MemberService._();

  static final MemberService instance = MemberService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
  FirebaseFunctions.instanceFor(region: 'europe-west2');

  /// Promote a member to LEADER for a given ministry.
  ///
  /// `ministryIdOrName` can be either:
  ///  - the ministry document ID, or
  ///  - the ministry NAME
  ///
  /// Backend: calls `setMinistryLeadership` Cloud Function.
  /// Only pastors/admins or leaders of that ministry can perform this.
  Future<void> promoteToLeader({
    required String memberId,
    required String ministryIdOrName,
    bool allowLastLeader = false,
  }) async {
    final callable = _functions.httpsCallable('setMinistryLeadership');
    await callable.call(<String, dynamic>{
      'memberId': memberId,
      'ministryId': ministryIdOrName,
      'makeLeader': true,
      'allowLastLeader': allowLastLeader,
    });
  }

  /// Demote a member from LEADER for a given ministry.
  ///
  /// If this is the last leader for that ministry and:
  ///  - caller is NOT a pastor/admin
  ///  - `allowLastLeader` is false
  /// the backend will reject with `would-remove-last-leader`.
  Future<void> demoteFromLeader({
    required String memberId,
    required String ministryIdOrName,
    bool allowLastLeader = false,
  }) async {
    final callable = _functions.httpsCallable('setMinistryLeadership');
    await callable.call(<String, dynamic>{
      'memberId': memberId,
      'ministryId': ministryIdOrName,
      'makeLeader': false,
      'allowLastLeader': allowLastLeader,
    });
  }

  /// Remove a member from a ministry (and leadership there, if present).
  ///
  /// Backend: `removeMemberFromMinistry` callable.
  /// Parity: pastors/admins OR leaders of that ministry.
  ///
  /// This will:
  /// - Remove ministry from `members.ministries`
  /// - Remove ministry from `members.leadershipMinistries`
  /// - Drop `leader` role if they are no longer a leader anywhere
  /// - Mirror all of that to `users` + sync claims.
  Future<void> removeFromMinistry({
    required String memberId,
    required String ministryIdOrName,
    bool allowLastLeaderRemoval = false,
  }) async {
    final callable = _functions.httpsCallable('removeMemberFromMinistry');
    await callable.call(<String, dynamic>{
      'memberId': memberId,
      'ministryId': ministryIdOrName,
      'allowLastLeaderRemoval': allowLastLeaderRemoval,
    });
  }

  /// Bulk-add or remove roles for one or more members.
  ///
  /// Backend: `setMemberRoles` callable.
  /// Only pastors/admins can call this.
  ///
  /// Examples:
  ///  - add 'usher' role to a list of members
  ///  - remove 'leader' role from several members
  ///
  /// NOTE: roles here are the same strings used in your backend:
  ///   'member', 'usher', 'leader', 'pastor', 'admin', 'media'
  Future<int> setMemberRoles({
    required List<String> memberIds,
    List<String> rolesToAdd = const [],
    List<String> rolesToRemove = const [],
  }) async {
    final callable = _functions.httpsCallable('setMemberRoles');
    final res = await callable.call(<String, dynamic>{
      'memberIds': memberIds,
      'rolesAdd': rolesToAdd,
      'rolesRemove': rolesToRemove,
    });

    final data = res.data;
    if (data is Map && data['updated'] is int) {
      return data['updated'] as int;
    }
    return 0;
  }

  /// Toggle 'pastor' for a specific member.
  ///
  /// Backend: `setMemberPastorRole` callable.
  /// Only pastors/admins can call this.
  Future<void> setPastorStatus({
    required String memberId,
    required bool makePastor,
  }) async {
    final callable = _functions.httpsCallable('setMemberPastorRole');
    await callable.call(<String, dynamic>{
      'memberId': memberId,
      'makePastor': makePastor,
    });
  }

  /// Read a member document.
  /// (Convenience for profile screens / admin tools.)
  Future<DocumentSnapshot<Map<String, dynamic>>> getMember(String memberId) {
    return _db.collection('members').doc(memberId).get();
  }

  /// Stream a member document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> watchMember(String memberId) {
    return _db.collection('members').doc(memberId).snapshots();
  }
}
