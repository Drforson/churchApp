// lib/services/notification_center.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Centralized helper for writing and reading notifications.
///
/// Document shapes written here:
///
/// 1) Leader broadcast when a member requests to join a ministry:
///    {
///      type: 'join_request',
///      ministryId: <MINISTRY_NAME>,          // name (matches members[].ministries)
///      ministryDocId: <ministries/{docId}>,  // optional but recommended
///      joinRequestId: <join_requests/{docId}>,
///      requestedByUid: <uid>,
///      memberId: <members/{id}>,
///      createdAt: <server timestamp>,
///      audience: { leadersOnly: true, adminAlso: true }
///    }
///
/// 2) Direct notification to each leader (fan-out of #1):
///    {
///      type: 'join_request',
///      ministryId, ministryDocId, joinRequestId, requestedByUid, memberId,
///      recipientUid: <leader uid>,           // <— direct
///      createdAt,
///      audience: { direct: true, role: 'leader' }
///    }
///
/// 3) Result notification to requester (approve/reject):
///    {
///      type: 'join_request_result',
///      result: 'approved' | 'rejected',
///      ministryId, ministryDocId, joinRequestId,
///      memberId: <requester members/{id}>,
///      recipientUid: <requester uid>,        // <— direct
///      moderatorUid: <leader/admin uid>,     // optional
///      createdAt
///    }
class NotificationCenter {
  /// Singleton instance so `NotificationCenter.I` is valid.
  static final NotificationCenter I = NotificationCenter._();
  NotificationCenter._();

  /// Optional init hook for future bootstrapping (safe no-op).
  static Future<void> init() async {
    // Add any startup wiring here if needed later (e.g., topic subs, cache).
    return;
  }

  // Collection names
  static const String _col = 'notifications';
  static const String _usersCol = 'users';
  static const String _membersCol = 'members';

  // ---------------------------------------------------------------------------
  // WRITE HELPERS
  // ---------------------------------------------------------------------------

  /// Broadcast + direct fan-out when a member requests to join.
  static Future<void> notifyJoinRequested({
    required String ministryName,      // human-readable NAME
    required String ministryDocId,     // ministries/{docId}
    required String joinRequestId,     // join_requests/{docId}
    required String requesterUid,      // uid of requester
    required String requesterMemberId, // members/{id}
  }) async {
    final db = FirebaseFirestore.instance;

    // 1) Broadcast for leaders/admins
    await db.collection(_col).add({
      'type': 'join_request',
      'ministryId': ministryName,
      'ministryDocId': ministryDocId,
      'joinRequestId': joinRequestId,
      'requestedByUid': requesterUid,
      'memberId': requesterMemberId,
      'createdAt': FieldValue.serverTimestamp(),
      'audience': {'leadersOnly': true, 'adminAlso': true},
    });

    // 2) Direct fan-out to leaders (resolve member -> user uid)
    final leaderMembers = await db
        .collection(_membersCol)
        .where('leadershipMinistries', arrayContains: ministryName)
        .get();

    if (leaderMembers.docs.isEmpty) return;

    final batch = db.batch();
    for (final lm in leaderMembers.docs) {
      final leaderMemberId = lm.id;
      final userQs = await db
          .collection(_usersCol)
          .where('memberId', isEqualTo: leaderMemberId)
          .limit(1)
          .get();
      if (userQs.docs.isEmpty) continue;

      final leaderUid = userQs.docs.first.id;
      batch.set(db.collection(_col).doc(), {
        'type': 'join_request',
        'ministryId': ministryName,
        'ministryDocId': ministryDocId,
        'joinRequestId': joinRequestId,
        'requestedByUid': requesterUid,
        'memberId': requesterMemberId,
        'recipientUid': leaderUid, // direct to leader
        'createdAt': FieldValue.serverTimestamp(),
        'audience': {'direct': true, 'role': 'leader'},
      });
    }
    await batch.commit();
  }

  /// Direct result to requester when leader approves/rejects.
  static Future<void> notifyJoinResult({
    required String ministryName,
    required String ministryDocId,
    required String joinRequestId,
    required String requesterMemberId,
    required String result, // 'approved' | 'rejected'
    String? moderatorUid,
  }) async {
    assert(result == 'approved' || result == 'rejected');

    final db = FirebaseFirestore.instance;

    String? recipientUid;
    final qs = await db
        .collection(_usersCol)
        .where('memberId', isEqualTo: requesterMemberId)
        .limit(1)
        .get();
    if (qs.docs.isNotEmpty) recipientUid = qs.docs.first.id;

    await db.collection(_col).add({
      'type': 'join_request_result',
      'result': result,
      'ministryId': ministryName,
      'ministryDocId': ministryDocId,
      'joinRequestId': joinRequestId,
      'memberId': requesterMemberId,
      if (recipientUid != null) 'recipientUid': recipientUid,
      if (moderatorUid != null) 'moderatorUid': moderatorUid,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Optional: notify leaders that a pending request was cancelled by the requester.
  static Future<void> notifyJoinCancelled({
    required String ministryName,
    required String ministryDocId,
    required String joinRequestId,
    required String requesterUid,
    required String requesterMemberId,
  }) async {
    final db = FirebaseFirestore.instance;

    // Broadcast
    await db.collection(_col).add({
      'type': 'join_request_cancelled',
      'ministryId': ministryName,
      'ministryDocId': ministryDocId,
      'joinRequestId': joinRequestId,
      'requestedByUid': requesterUid,
      'memberId': requesterMemberId,
      'createdAt': FieldValue.serverTimestamp(),
      'audience': {'leadersOnly': true, 'adminAlso': true},
    });

    // Direct fan-out
    final leaderMembers = await db
        .collection(_membersCol)
        .where('leadershipMinistries', arrayContains: ministryName)
        .get();
    if (leaderMembers.docs.isEmpty) return;

    final batch = db.batch();
    for (final lm in leaderMembers.docs) {
      final leaderMemberId = lm.id;
      final userQs = await db
          .collection(_usersCol)
          .where('memberId', isEqualTo: leaderMemberId)
          .limit(1)
          .get();
      if (userQs.docs.isEmpty) continue;
      final leaderUid = userQs.docs.first.id;

      batch.set(db.collection(_col).doc(), {
        'type': 'join_request_cancelled',
        'ministryId': ministryName,
        'ministryDocId': ministryDocId,
        'joinRequestId': joinRequestId,
        'requestedByUid': requesterUid,
        'memberId': requesterMemberId,
        'recipientUid': leaderUid,
        'createdAt': FieldValue.serverTimestamp(),
        'audience': {'direct': true, 'role': 'leader'},
      });
    }
    await batch.commit();
  }

  // ---------------------------------------------------------------------------
  // READ HELPERS (for Notification Center screens)
  // ---------------------------------------------------------------------------

  /// Direct notifications for a specific user (For You).
  static Stream<List<Map<String, dynamic>>> streamForUser({
    required String uid,
  }) {
    final db = FirebaseFirestore.instance;
    return db
        .collection(_col)
        .where('recipientUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => {'id': d.id, ...d.data()}).toList());
  }

  /// Leader broadcasts for ministries the user leads (admins see all).
  static Stream<List<Map<String, dynamic>>> streamLeaderBroadcasts({
    required bool isAdmin,
    required Set<String> leadershipMinistryNames,
  }) {
    final db = FirebaseFirestore.instance;
    final base = db
        .collection(_col)
        .where('type', isEqualTo: 'join_request')
        .where('audience.leadersOnly', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => {'id': d.id, ...d.data()}).toList());

    if (isAdmin) return base;
    if (leadershipMinistryNames.isEmpty) return const Stream.empty();

    return base.map((items) => items
        .where((n) => leadershipMinistryNames
        .contains((n['ministryId'] ?? '').toString()))
        .toList());
  }

  /// Combined stream emitting both buckets whenever either changes.
  static Stream<Map<String, List<Map<String, dynamic>>>> combinedStream({
    required String uid,
    required bool isAdmin,
    required Set<String> leadershipMinistryNames,
  }) {
    final forYou$ = streamForUser(uid: uid);
    final leader$ = streamLeaderBroadcasts(
      isAdmin: isAdmin,
      leadershipMinistryNames: leadershipMinistryNames,
    );

    final controller =
    StreamController<Map<String, List<Map<String, dynamic>>>>();

    List<Map<String, dynamic>> latestForYou = const [];
    List<Map<String, dynamic>> latestLeader = const [];

    StreamSubscription<List<Map<String, dynamic>>>? subA;
    StreamSubscription<List<Map<String, dynamic>>>? subB;

    void emit() {
      if (!controller.isClosed) {
        controller.add({
          'forYou': latestForYou,
          'leaderAlerts': latestLeader,
        });
      }
    }

    subA = forYou$.listen((data) {
      latestForYou = data;
      emit();
    }, onError: controller.addError);

    subB = leader$.listen((data) {
      latestLeader = data;
      emit();
    }, onError: controller.addError);

    controller.onCancel = () async {
      await subA?.cancel();
      await subB?.cancel();
    };

    return controller.stream;
  }
}
