import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../pages/notification_center_page.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  final _db = FirebaseFirestore.instance;
  String? _uid;
  List<String> _roles = const [];
  List<String> _myRequestIds = const [];

  Stream<int>? _countStream;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_uid == null) return;
    _roles = await _loadUserRoles(_uid!);
    _myRequestIds = await _loadMyRecentRequestIds(_uid!);
    setState(() {
      _countStream = _buildUnreadCountStream(_uid!, _roles, _myRequestIds);
    });
  }

  Future<List<String>> _loadUserRoles(String uid) async {
    try {
      final doc = await _db.collection('users').doc(uid).get();
      if (!doc.exists) return const [];
      return List<String>.from((doc.data() ?? const {})['roles'] ?? const <String>[]);
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _loadMyRecentRequestIds(String uid) async {
    try {
      final snap = await _db
          .collection('ministry_creation_requests')
          .where('requestedByUid', isEqualTo: uid)
          .orderBy('requestedAt', descending: true)
          .limit(10)
          .get();
      return snap.docs.map((d) => d.id).toList();
    } catch (_) {
      return const [];
    }
  }

  Stream<int> _buildUnreadCountStream(String uid, List<String> roles, List<String> reqIds) {
    // Inbox (personal)
    final inbox$ = _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .map((s) => s.docs.where((d) => (d.data()['read'] != true)).length);

    // Direct notifications
    final direct$ = _db
        .collection('notifications')
        .where('toUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
    // Some docs may not have `read` -> treat as unread
        .map((s) => s.docs.where((d) => (d.data()['read'] != true)).length);

    // Role-based (optional)
    Stream<int> role$ = Stream.value(0);
    if (roles.isNotEmpty) {
      role$ = _db
          .collection('notifications')
          .where('toRole', whereIn: roles.take(10).toList())
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots()
          .map((s) => s.docs.where((d) => (d.data()['read'] != true)).length);
    }

    // Requester notifications (optional)
    Stream<int> requester$ = Stream.value(0);
    if (reqIds.isNotEmpty) {
      requester$ = _db
          .collection('notifications')
          .where('toRequester', isEqualTo: true)
          .where('requestId', whereIn: reqIds.take(10).toList())
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .map((s) => s.docs.where((d) => (d.data()['read'] != true)).length);
    }

    return Rx.combineLatest4<int, int, int, int, int>(
      inbox$,
      direct$,
      role$,
      requester$,
          (a, b, c, d) => a + b + c + d,
    );
  }

  void _openCenter() {
    final uid = _uid;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NotificationCenterPage(uid: uid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return IconButton(
        icon: const Icon(Icons.notifications_none),
        onPressed: null,
        tooltip: 'Notifications',
      );
    }

    if (_countStream == null) {
      // Loading roles/my requests
      return IconButton(
        icon: const Icon(Icons.notifications_none),
        onPressed: _openCenter,
        tooltip: 'Notifications',
      );
    }

    return StreamBuilder<int>(
      stream: _countStream,
      builder: (context, snap) {
        final count = (snap.data ?? 0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: Icon(count > 0 ? Icons.notifications_active : Icons.notifications_none),
              tooltip: 'Notifications',
              onPressed: _openCenter,
            ),
            if (count > 0)
              Positioned(
                right: 6,
                top: 6,
                child: _Badge(count: count),
              ),
          ],
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;
  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : count.toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 2, offset: const Offset(0, 1)),
        ],
      ),
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
        textAlign: TextAlign.center,
      ),
    );
  }
}
