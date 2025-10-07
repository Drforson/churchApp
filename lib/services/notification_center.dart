import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Server-first Notification Center:
/// - Canonical personal feed: inbox/{uid}/events (written by Cloud Functions)
/// - Legacy role/requester notifications live in `notifications` collection; UI reads them,
///   but we DO NOT mirror/write client duplicates into inbox anymore.
///
/// This service exposes helpers to mark items read/delete and a combined
/// stream if needed by other widgets.

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter I = NotificationCenter._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  /// Stream of inbox events for current user (most recent first).
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> inboxEventsStream({
    int limit = 200,
  }) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();

    return _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .withConverter<Map<String, dynamic>>(
      fromFirestore: (s, _) => s.data() ?? <String, dynamic>{},
      toFirestore: (m, _) => m,
    )
        .snapshots()
        .map((s) => s.docs);
  }

  /// Stream of role/requester based notifications visible to current user.
  /// NOTE: Firestore doesn't support OR; caller usually merges the three streams in UI.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> toUidNotifications({
    int limit = 100,
  }) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();

    return _db
        .collection('notifications')
        .where('toUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .withConverter<Map<String, dynamic>>(
      fromFirestore: (s, _) => s.data() ?? <String, dynamic>{},
      toFirestore: (m, _) => m,
    )
        .snapshots()
        .map((s) => s.docs);
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> toRoleNotifications({
    required List<String> roles,
    int limit = 100,
  }) {
    if (roles.isEmpty) return const Stream.empty();
    // If there are multiple roles, we fetch for the FIRST role for simplicity.
    // (If you need full coverage, create multiple builders in the page.)
    return _db
        .collection('notifications')
        .where('toRole', isEqualTo: roles.first)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .withConverter<Map<String, dynamic>>(
      fromFirestore: (s, _) => s.data() ?? <String, dynamic>{},
      toFirestore: (m, _) => m,
    )
        .snapshots()
        .map((s) => s.docs);
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> requesterNotifications({
    int limit = 100,
  }) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('notifications')
        .where('toRequester', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .withConverter<Map<String, dynamic>>(
      fromFirestore: (s, _) => s.data() ?? <String, dynamic>{},
      toFirestore: (m, _) => m,
    )
        .snapshots()
        .map((s) => s.docs);
  }

  /// Mark a single inbox event as read.
  Future<void> markInboxEventRead(String eventId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('inbox').doc(uid).collection('events').doc(eventId).update({
      'read': true,
      'readAt': FieldValue.serverTimestamp(),
    });
  }

  /// Delete a single inbox event.
  Future<void> deleteInboxEvent(String eventId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('inbox').doc(uid).collection('events').doc(eventId).delete();
  }

  /// Mark *all* inbox events as read.
  Future<void> markAllInboxRead() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final batch = _db.batch();
    final qs = await _db.collection('inbox').doc(uid).collection('events').where('read', isEqualTo: false).get();
    for (final d in qs.docs) {
      batch.update(d.reference, {'read': true, 'readAt': FieldValue.serverTimestamp()});
    }
    await batch.commit();
  }

  /// Legacy notifications helpers
  Future<void> markNotificationRead(String id) async {
    await _db.collection('notifications').doc(id).update({
      'read': true,
      'readAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteNotification(String id) async {
    await _db.collection('notifications').doc(id).delete();
  }

  /// Utility to compute a simple unread count for the bell.
  /// (You may still have a custom bell widget summing multiple sources.)
  Future<int> unreadInboxCount() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return 0;
    final qs = await _db.collection('inbox').doc(uid).collection('events').where('read', isEqualTo: false).get();
    return qs.size;
  }
}
