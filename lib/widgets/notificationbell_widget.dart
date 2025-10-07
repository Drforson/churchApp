// lib/widgets/notification_bell.dart
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

  StreamSubscription<User?>? _authSub;
  Stream<int>? _countStream;

  int _bootGen = 0; // generation token to cancel stale async work

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
    _bootstrap();

    // React to auth changes (sign in/out) safely.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) async {
      _uid = u?.uid;
      if (_uid == null) {
        if (!mounted) return;
        setState(() {
          _roles = const [];
          _myRequestIds = const [];
          _countStream = null;
        });
        return;
      }
      await _bootstrap();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _authSub = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final uid = _uid;
    if (uid == null) return;

    // bump generation; capture local copy
    final myGen = ++_bootGen;

    final roles = await _loadUserRoles(uid);
    if (!mounted || myGen != _bootGen) return;

    final requestIds = await _loadMyRecentRequestIds(uid);
    if (!mounted || myGen != _bootGen) return;

    final stream = _buildUnreadCountStream(uid, roles, requestIds);
    if (!mounted || myGen != _bootGen) return;

    setState(() {
      _roles = roles;
      _myRequestIds = requestIds;
      _countStream = stream;
    });
  }

  Future<List<String>> _loadUserRoles(String uid) async {
    try {
      final doc = await _db.collection('users').doc(uid).get();
      if (!doc.exists) return const [];
      final data = doc.data() ?? const {};
      return (data['roles'] is List)
          ? List<String>.from(data['roles'])
          : const <String>[];
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
    // Inbox (personal, server-authored) — tolerate legacy docs without `read` field
    final inbox$ = _db
        .collection('inbox')
        .doc(uid)
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots()
        .map((s) => s.docs.where((d) => (d.data()['read'] != true)).length);

    // Direct notifications (legacy collection) — keep strict read==false
    final direct$ = _db
        .collection('notifications')
        .where('toUid', isEqualTo: uid)
        .where('read', isEqualTo: false)
        .limit(200)
        .snapshots()
        .map((s) => s.size);

    // Role-based notifications (legacy). Firestore whereIn cap = 10.
    Stream<int> role$ = Stream.value(0);
    if (roles.isNotEmpty) {
      role$ = _db
          .collection('notifications')
          .where('toRole', whereIn: roles.take(10).toList())
          .where('read', isEqualTo: false)
          .limit(200)
          .snapshots()
          .map((s) => s.size);
    }

    // Requester notifications (legacy) for my recent requests
    Stream<int> requester$ = Stream.value(0);
    if (reqIds.isNotEmpty) {
      requester$ = _db
          .collection('notifications')
          .where('toRequester', isEqualTo: true)
          .where('requestId', whereIn: reqIds.take(10).toList())
          .where('read', isEqualTo: false)
          .limit(200)
          .snapshots()
          .map((s) => s.size);
    }

    return Rx.combineLatest4<int, int, int, int, int>(
      inbox$,
      direct$,
      role$,
      requester$,
          (a, b, c, d) => a + b + c + d,
    ).distinct();
  }

  void _openCenter() {
    if (_uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NotificationCenterPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_uid == null) {
      return IconButton(
        icon: const Icon(Icons.notifications_none),
        onPressed: null,
        tooltip: 'Notifications',
      );
    }

    if (_countStream == null) {
      // Still loading roles/requests; allow opening center anyway.
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
