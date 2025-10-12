// lib/services/notification_center.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Canonical inbox event model for inbox/{uid}/events.
/// Keep fields nullable for UI safety; use `raw` if you need extra payload.
class InboxEvent {
  final String id;
  final String? title;
  final String? body;
  final String? type;       // e.g., "join_request.approved"
  final DateTime? createdAt;
  final bool read;
  final Map<String, dynamic> raw;

  InboxEvent({
    required this.id,
    this.title,
    this.body,
    this.type,
    this.createdAt,
    required this.read,
    required this.raw,
  });

  static InboxEvent fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final ts = data['createdAt'];
    DateTime? created;
    if (ts is Timestamp) created = ts.toDate();

    String? cleanStr(dynamic v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    return InboxEvent(
      id: doc.id,
      title: cleanStr(data['title']),
      body: cleanStr(data['body']),
      type: cleanStr(data['type']),
      createdAt: created,
      read: (data['read'] is bool) ? data['read'] as bool : false,
      raw: data,
    );
  }

  Map<String, dynamic> toFirestore() => raw;
}

/// Centralized read/write facade for the canonical inbox.
class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter I = NotificationCenter._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  /// Returns a typed reference to inbox/{uid}/events with converter.
  CollectionReference<InboxEvent>? _eventsRefFor(String uid) {
    if (uid.isEmpty) return null;
    return _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .withConverter<InboxEvent>(
      fromFirestore: (snap, _) => InboxEvent.fromFirestore(snap),
      toFirestore: (ev, _) => ev.toFirestore(),
    );
  }

  // ---------------------------------------------------------------------------
  // STREAMS
  // ---------------------------------------------------------------------------

  /// Live unread count for the currently-authenticated user.
  Stream<int> unreadCountStream() {
    return _auth.authStateChanges().switchMap((user) {
      if (user == null) return  Stream<int>.value(0);
      final ref = _eventsRefFor(user.uid);
      if (ref == null) return  Stream<int>.value(0);
      return ref.where('read', isEqualTo: false).snapshots().map((s) => s.size);
    });
  }

  /// Live inbox events (most recent first) for the current user.
  Stream<List<InboxEvent>> inboxEventsStream({int limit = 200}) {
    return _auth.authStateChanges().switchMap((user) {
      if (user == null) {
        return  Stream<List<InboxEvent>>.value(<InboxEvent>[]);
      }
      final ref = _eventsRefFor(user.uid);
      if (ref == null) {
        return  Stream<List<InboxEvent>>.value(<InboxEvent>[]);
      }
      return ref
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());
    });
  }

  // ---------------------------------------------------------------------------
  // ACTIONS
  // ---------------------------------------------------------------------------

  /// Mark a single event as read.
  Future<void> markRead(String eventId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final ref = _eventsRefFor(uid);
    if (ref == null) return;
    await ref.doc(eventId).update({'read': true});
  }

  /// Mark all unread events as read (efficient batched updates).
  Future<void> markAllRead() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final ref = _eventsRefFor(uid);
    if (ref == null) return;

    final unread = await ref.where('read', isEqualTo: false).get();
    if (unread.docs.isEmpty) return;

    WriteBatch? batch;
    var i = 0;
    for (final d in unread.docs) {
      batch ??= _db.batch();
      batch.update(d.reference, {'read': true});
      i++;
      // Keep a safe margin under Firestore's ~500 ops/batch limit.
      if (i % 450 == 0) {
        await batch.commit();
        batch = null;
      }
    }
    if (batch != null) await batch.commit();
  }

  /// Delete an event from the inbox.
  Future<void> deleteEvent(String eventId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final ref = _eventsRefFor(uid);
    if (ref == null) return;
    await ref.doc(eventId).delete();
  }

  /// (Optional) Utility to create an event for the current user.
  /// Useful for local testing or ad-hoc app-generated notices.
  Future<void> createEvent({
    required String type,
    String? title,
    String? body,
    Map<String, dynamic>? extra,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final ref = _eventsRefFor(uid);
    if (ref == null) return;

    final data = <String, dynamic>{
      'type': type,
      if (title != null) 'title': title,
      if (body != null) 'body': body,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
      if (extra != null) ...extra,
    };

    await ref.add(InboxEvent(
      id: 'pending',
      type: type,
      title: title,
      body: body,
      createdAt: null,
      read: false,
      raw: data,
    ));
  }
}

// -----------------------------------------------------------------------------
// Lightweight switchMap so we don't need rx_dart or streams_extensions.
// -----------------------------------------------------------------------------
extension _SwitchMap<T> on Stream<T> {
  Stream<R> switchMap<R>(Stream<R> Function(T value) project) async* {
    StreamSubscription<R>? innerSub;
    final controller = StreamController<R>();
    late final StreamSubscription<T> outerSub;

    outerSub = listen((outerValue) {
      innerSub?.cancel();
      innerSub = project(outerValue).listen(
        controller.add,
        onError: controller.addError,
      );
    }, onError: controller.addError, onDone: () async {
      await innerSub?.cancel();
      await controller.close();
    });

    yield* controller.stream;
    await outerSub.cancel();
  }
}
