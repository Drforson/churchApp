// lib/pages/notification_center_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart'; // for navigation on tap

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;

  String? _uid;
  Set<String> _roles = {};
  bool get _isAdmin => _roles.map((e) => e.toLowerCase()).contains('admin');
  bool get _isLeader => _roles.map((e) => e.toLowerCase()).contains('leader');
  Set<String> _leaderMinistriesByName = {}; // names, not ids

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final userSnap = await _db.collection('users').doc(uid).get();
    final data = userSnap.data() ?? {};
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : <String>[];
    final leaderMins = (data['leadershipMinistries'] is List)
        ? Set<String>.from(data['leadershipMinistries'])
        : <String>{};

    setState(() {
      _uid = uid;
      _roles = roles.toSet();
      _leaderMinistriesByName = leaderMins;
    });
  }

  // -------------------- Streams --------------------

  /// Direct notifications sent to this user (For You).
  Stream<List<Map<String, dynamic>>> _forYouStream() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('notifications')
        .where('recipientUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => {'id': d.id, ...d.data()}).toList());
  }

  /// Leader broadcasts (join_request) for ministries the user leads.
  /// Admins see all leader broadcasts.
  Stream<List<Map<String, dynamic>>> _leaderAlertsStream() {
    if (!_isAdmin && !_isLeader) return const Stream.empty();

    final base = _db
        .collection('notifications')
        .where('type', isEqualTo: 'join_request')
        .where('audience.leadersOnly', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => {'id': d.id, ...d.data()}).toList());

    if (_isAdmin) {
      // Admin sees all broadcasts
      return base;
    }

    // Leaders: filter to ministries they actually lead (by name)
    return base.map((items) => items
        .where((n) => _leaderMinistriesByName
        .contains((n['ministryId'] ?? '').toString()))
        .toList());
  }

  // -------------------- UI helpers --------------------

  String _fmtWhen(dynamic ts) {
    final dt = (ts is Timestamp) ? ts.toDate() : null;
    if (dt == null) return '—';
    return DateFormat('dd MMM, HH:mm').format(dt);
  }

  Icon _iconFor(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();
    switch (type) {
      case 'join_request':
        return const Icon(Icons.group_add);
      case 'join_request_result':
        final result = (n['result'] ?? '').toString();
        return Icon(result == 'approved' ? Icons.check_circle : Icons.cancel);
      case 'join_request_cancelled':
        return const Icon(Icons.undo);
      default:
        return const Icon(Icons.notifications_none);
    }
  }

  String _titleFor(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();
    switch (type) {
      case 'join_request':
        return 'New join request';
      case 'join_request_result':
        final result = (n['result'] ?? '').toString();
        if (result == 'approved') return 'Your join request was approved';
        if (result == 'rejected') return 'Your join request was rejected';
        return 'Join request updated';
      case 'join_request_cancelled':
        return 'Join request cancelled';
      default:
        return 'Notification';
    }
  }

  String _subtitleFor(Map<String, dynamic> n) {
    final ministryName = (n['ministryId'] ?? '').toString();
    final when = _fmtWhen(n['createdAt']);
    if (ministryName.isEmpty) return when;
    return '$ministryName • $when';
  }

  /// Try to navigate to Ministry Details from a notification.
  /// If ministryDocId is missing, we can still open using name-only (your details page checks access).
  void _openMinistryFrom(Map<String, dynamic> n) {
    final ministryDocId = (n['ministryDocId'] ?? '').toString();
    final ministryName = (n['ministryId'] ?? '').toString();

    if (ministryName.isEmpty && ministryDocId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This notification is missing ministry information.')),
      );
      return;
    }

    // If missing docId, we can’t show feed/posts by id, but navigation can still be attempted with a guard
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MinistryDetailsPage(
        ministryId: ministryDocId.isNotEmpty ? ministryDocId : 'unknown', // defensive; page is name-gated
        ministryName: ministryName.isNotEmpty ? ministryName : '(Unknown Ministry)',
      ),
    ));
  }

  Widget _tileFor(Map<String, dynamic> n, {bool leaderTile = false}) {
    final icon = _iconFor(n);
    final title = _titleFor(n);
    final subtitle = _subtitleFor(n);
    final type = (n['type'] ?? '').toString();

    // Leader tiles are actionable (go moderate). Member result tiles are also actionable (go see).
    final canOpen = type == 'join_request' || type == 'join_request_result';

    return ListTile(
      leading: icon,
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: canOpen ? () => _openMinistryFrom(n) : null,
      trailing: canOpen
          ? OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new),
        label: Text(leaderTile ? 'Open' : 'View'),
        onPressed: () => _openMinistryFrom(n),
      )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final forYou = _forYouStream();
    final leader = _leaderAlertsStream();

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: Column(
        children: [
          // -------- For You (direct notifications) --------
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: forYou,
              builder: (context, snap) {
                final items = snap.data ?? const <Map<String, dynamic>>[];
                return _Section(
                  title: 'For you',
                  emptyText: 'No notifications.',
                  child: items.isEmpty
                      ? null
                      : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 0),
                    itemBuilder: (_, i) => _tileFor(items[i]),
                  ),
                );
              },
            ),
          ),

          const Divider(height: 0),

          // -------- Leader Alerts (broadcast) --------
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: leader,
              builder: (context, snap) {
                final items = snap.data ?? const <Map<String, dynamic>>[];
                return _Section(
                  title: 'Leader alerts',
                  emptyText: _isAdmin || _isLeader
                      ? 'No leader alerts.'
                      : 'You are not a leader of any ministry.',
                  child: items.isEmpty
                      ? null
                      : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 0),
                    itemBuilder: (_, i) => _tileFor(items[i], leaderTile: true),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String emptyText;
  final Widget? child;

  const _Section({
    required this.title,
    required this.emptyText,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = child == null;
    return Column(
      children: [
        ListTile(
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(emptyText, style: Theme.of(context).textTheme.bodyMedium),
          )
        else
          Expanded(child: child!),
      ],
    );
  }
}
