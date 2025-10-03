// lib/services/notification_center.dart
//
// Real-time notification hub.
// - Writes notifications for: ministry feed posts, my join-request status,
//   and leader pending join-requests.
// - Exposes a stream<NotificationState> your UI can render.
// - Stores events in inbox/{uid}/events so the NotificationCenterPage sees them.

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

enum NotificationChannel { feeds, joinreq, leader_joinreq }

class AppNotification {
  final String id;
  final String title;
  final String body;
  final NotificationChannel channel;
  final DateTime createdAt;
  final bool read;
  final String? ministryId;
  final String? ministryName;
  final Map<String, dynamic> payload;

  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.channel,
    required this.createdAt,
    required this.read,
    this.ministryId,
    this.ministryName,
    this.payload = const {},
  });

  static NotificationChannel _parseChannel(dynamic v) {
    final s = (v ?? '').toString();
    switch (s) {
      case 'feeds':
        return NotificationChannel.feeds;
      case 'joinreq':
        return NotificationChannel.joinreq;
      case 'leader_joinreq':
        return NotificationChannel.leader_joinreq;
      default:
        return NotificationChannel.feeds;
    }
  }

  factory AppNotification.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final ts = d['createdAt'];
    DateTime when;
    if (ts is Timestamp) {
      when = ts.toDate();
    } else {
      when = DateTime.fromMillisecondsSinceEpoch(0);
    }
    final payload = Map<String, dynamic>.from(d['payload'] ?? {});
    return AppNotification(
      id: doc.id,
      title: (d['title'] ?? '').toString(),
      body: (d['body'] ?? '').toString(),
      channel: _parseChannel(d['channel']),
      createdAt: when,
      read: d['read'] == true,
      ministryId: (payload['ministryId'] ?? d['ministryId'])?.toString(),
      ministryName: (payload['ministryName'] ?? d['ministryName'])?.toString(),
      payload: payload,
    );
  }
}

class NotificationState {
  final List<AppNotification> items;
  final int unread;

  const NotificationState({this.items = const [], this.unread = 0});

  NotificationState copyWith({List<AppNotification>? items, int? unread}) =>
      NotificationState(items: items ?? this.items, unread: unread ?? this.unread);
}

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  // --------------- public stream ---------------
  final _stateCtrl = StreamController<NotificationState>.broadcast();
  NotificationState _state = const NotificationState();

  Stream<NotificationState> get stream => _stateCtrl.stream;

  void _emit(NotificationState s) {
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  // --------------- auth / lifecycle ---------------
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userDocSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _memberDocSub;

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _feedPostSubs = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _myJoinReqSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _leaderJoinReqSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _inboxSub;

  String? _uid;
  String? _memberId;
  Set<String> _memberMinistryNames = {};
  Set<String> _leadMinistryNames = {};
  DateTime _sessionStart = DateTime.now();

  // ----------------- PUBLIC API -----------------

  void bindToAuth() {
    _authSub?.cancel();
    _authSub = _auth.authStateChanges().listen((user) async {
      if (user == null) {
        await stop();
      } else {
        await startForUser(user.uid);
      }
    });
  }

  Future<void> startForCurrentUser() async {
    final u = _auth.currentUser;
    if (u != null) await startForUser(u.uid);
  }

  Future<void> startForUser(String uid) async {
    await stop();
    _sessionStart = DateTime.now();
    _uid = uid;

    // Listen to inbox (inbox/{uid}/events) to feed the UI state
    _bindInbox(uid);

    // Listen to users doc for roles/member links
    _userDocSub = _db.collection('users').doc(uid).snapshots().listen((snap) async {
      final data = snap.data() ?? {};
      final leadFromUsers = List<String>.from(data['leadershipMinistries'] ?? const <String>[]);
      final memberId = data['memberId'] as String?;
      _leadMinistryNames = leadFromUsers.toSet();

      if (_memberId != memberId) {
        _memberId = memberId;
        await _bindMemberDoc();
      }

      await _refreshAll();
    });
  }

  Future<void> stop() async {
    await _userDocSub?.cancel();
    await _memberDocSub?.cancel();
    await _myJoinReqSub?.cancel();
    await _leaderJoinReqSub?.cancel();
    await _inboxSub?.cancel();
    for (final s in _feedPostSubs) {
      await s.cancel();
    }
    _feedPostSubs.clear();

    _memberMinistryNames.clear();
    _leadMinistryNames.clear();
    _uid = null;
    _memberId = null;

    _emit(const NotificationState(items: [], unread: 0));
  }

  Future<void> dispose() async {
    await stop();
    await _authSub?.cancel();
    await _stateCtrl.close();
  }

  // Mark all in a channel as read (inbox)
  Future<void> markChannelSeen(NotificationChannel channel) async {
    final uid = _uid;
    if (uid == null) return;

    final channelKey = _channelKey(channel);
    final col = _db.collection('inbox').doc(uid).collection('events');
    final qs = await col.where('channel', isEqualTo: channelKey).where('read', isEqualTo: false).get();
    final batch = _db.batch();
    for (final d in qs.docs) {
      batch.update(d.reference, {'read': true});
    }
    await batch.commit();
  }

  // ----------------- internal binds -----------------

  Future<void> _bindMemberDoc() async {
    await _memberDocSub?.cancel();
    _memberDocSub = null;

    final memberId = _memberId;
    if (memberId == null || memberId.isEmpty) {
      _memberMinistryNames.clear();
      await _refreshAll();
      return;
    }

    _memberDocSub = _db.collection('members').doc(memberId).snapshots().listen((snap) async {
      final md = snap.data() ?? {};
      final mins = List<String>.from(md['ministries'] ?? const <String>[]);
      final leads = List<String>.from(md['leadershipMinistries'] ?? const <String>[]);
      _memberMinistryNames = mins.toSet();
      _leadMinistryNames = {..._leadMinistryNames, ...leads};
      await _refreshAll();
    });
  }

  Future<void> _refreshAll() async {
    await _bindFeedPostListeners();
    await _bindMyJoinRequestsListener();
    await _bindLeaderJoinRequestsListener();
  }

  void _bindInbox(String uid) {
    _inboxSub?.cancel();
    _inboxSub = _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .listen((qs) {
      final items = qs.docs.map(AppNotification.fromDoc).toList();
      final unread = items.where((n) => !n.read).length;
      _emit(NotificationState(items: items, unread: unread));
    });
  }

  Future<void> _bindFeedPostListeners() async {
    for (final s in _feedPostSubs) {
      await s.cancel();
    }
    _feedPostSubs.clear();

    if (_memberMinistryNames.isEmpty || _uid == null) return;

    // map ministry names -> ids
    final names = _memberMinistryNames.toList();
    const chunk = 10;
    for (var i = 0; i < names.length; i += chunk) {
      final part = names.sublist(i, (i + chunk).clamp(0, names.length));
      final idsSnap = await _db.collection('ministries').where('name', whereIn: part).get();

      for (final m in idsSnap.docs) {
        final minId = m.id;
        final mname = (m.data()['name'] ?? 'Ministry').toString();
        final sub = _db
            .collection('ministries')
            .doc(minId)
            .collection('posts')
            .where('createdAt', isGreaterThan: Timestamp.fromDate(_sessionStart))
            .orderBy('createdAt', descending: true)
            .limit(5)
            .snapshots()
            .listen((qs) async {
          for (final ch in qs.docChanges) {
            if (ch.type == DocumentChangeType.added) {
              final d = ch.doc.data() ?? {};
              final author = (d['authorName'] ?? 'Someone').toString();
              await _addNotification(
                channel: NotificationChannel.feeds,
                title: 'New post in $mname',
                body: '$author posted an update.',
                route: '/view-ministry',
                payload: {
                  'ministryId': minId,
                  'ministryName': mname,
                },
                dedupeKey: 'post_${ch.doc.id}',
              );
            }
          }
        });
        _feedPostSubs.add(sub);
      }
    }
  }

  Future<void> _bindMyJoinRequestsListener() async {
    await _myJoinReqSub?.cancel();
    _myJoinReqSub = null;
    if (_memberId == null || _uid == null) return;

    _myJoinReqSub = _db
        .collection('join_requests')
        .where('memberId', isEqualTo: _memberId)
        .snapshots()
        .listen((qs) async {
      for (final ch in qs.docChanges) {
        if (ch.type == DocumentChangeType.added || ch.type == DocumentChangeType.modified) {
          final d = ch.doc.data() ?? {};
          final status = (d['status'] ?? 'pending').toString();
          if (status == 'pending') continue;
          final ministryName = (d['ministryId'] ?? '').toString();

          await _addNotification(
            channel: NotificationChannel.joinreq,
            title: status == 'approved' ? 'Join request approved' : 'Join request ${status.toLowerCase()}',
            body: 'Your request to join "$ministryName" was $status.',
            route: '/view-ministry',
            payload: {'ministryName': ministryName},
            dedupeKey: 'jr_me_${ch.doc.id}_$status',
          );
        }
      }
    });
  }

  Future<void> _bindLeaderJoinRequestsListener() async {
    await _leaderJoinReqSub?.cancel();
    _leaderJoinReqSub = null;
    if (_leadMinistryNames.isEmpty || _uid == null) return;

    // chunk whereIn for ministry names (join_requests.ministryId is NAME)
    final names = _leadMinistryNames.toList();
    final queries = <Query<Map<String, dynamic>>>[];
    const chunk = 10;
    for (var i = 0; i < names.length; i += chunk) {
      final part = names.sublist(i, (i + chunk).clamp(0, names.length));
      queries.add(_db.collection('join_requests')
          .where('ministryId', whereIn: part)
          .where('status', isEqualTo: 'pending'));
    }

    if (queries.isEmpty) return;

    _leaderJoinReqSub = _mergeQueries(queries).listen((qs) async {
      for (final ch in qs.docChanges) {
        if (ch.type == DocumentChangeType.added) {
          final d = ch.doc.data() ?? {};
          final ministryName = (d['ministryId'] ?? 'Ministry').toString();

          // resolve memberName (members/{id})
          var requester = 'A member';
          final mid = (d['memberId'] ?? '').toString();
          if (mid.isNotEmpty) {
            final mem = await _db.collection('members').doc(mid).get();
            final md = mem.data();
            if (md != null) {
              final fn = (md['firstName'] ?? '').toString().trim();
              final ln = (md['lastName'] ?? '').toString().trim();
              final nm = '$fn $ln'.trim();
              if (nm.isNotEmpty) requester = nm;
            }
          }

          await _addNotification(
            channel: NotificationChannel.leader_joinreq,
            title: 'New join request',
            body: '$requester requested to join "$ministryName".',
            route: '/view-ministry',
            payload: {'ministryName': ministryName},
            dedupeKey: 'jr_leader_${ch.doc.id}',
          );
        }
      }
    }, onError: (e, st) {
      debugPrint('[NC] leader join req stream error: $e');
    });
  }

  // ----------------- helpers -----------------

  String _channelKey(NotificationChannel c) {
    switch (c) {
      case NotificationChannel.feeds:
        return 'feeds';
      case NotificationChannel.joinreq:
        return 'joinreq';
      case NotificationChannel.leader_joinreq:
        return 'leader_joinreq';
    }
  }

  /// ✅ Adds a notification event into inbox/{uid}/events (what the UI reads).
  Future<void> _addNotification({
    required NotificationChannel channel,
    required String title,
    required String body,
    required String route,
    Map<String, dynamic>? payload,
    String? dedupeKey,
  }) async {
    final uid = _uid;
    if (uid == null) return;

    final col = _db.collection('inbox').doc(uid).collection('events');
    final data = {
      // you can keep a general 'type' if needed by your UI/Functions
      'type': _channelKey(channel) == 'feeds' ? 'ministry_post' : 'join_request',
      'channel': _channelKey(channel), // 'feeds' | 'joinreq' | 'leader_joinreq'
      'title': title,
      'body': body,
      'route': route,
      'payload': payload ?? {},
      'ministryId': payload?['ministryId'],
      'ministryName': payload?['ministryName'],
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
    };

    if (dedupeKey != null && dedupeKey.isNotEmpty) {
      final ref = col.doc(dedupeKey);
      final exists = await ref.get();
      if (exists.exists) return;
      await ref.set(data, SetOptions(merge: false));
    } else {
      await col.add(data);
    }
  }

  /// Merge multiple queries into one stream by forwarding each snapshot.
  Stream<QuerySnapshot<Map<String, dynamic>>> _mergeQueries(
      List<Query<Map<String, dynamic>>> queries) {
    final controller = StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
    final subs = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

    for (final q in queries) {
      final sub = q.snapshots().listen(
        controller.add,
        onError: (e, st) {
          controller.addError(e, st);
        },
      );
      subs.add(sub);
    }

    controller.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return controller.stream;
  }
}
