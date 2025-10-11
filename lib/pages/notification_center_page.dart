// lib/pages/notification_center_page.dart
import 'dart:async';

import 'package:church_management_app/pages/pastor_ministry_approvals_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart';
//import 'pastor_join_requests_page.dart'; // ⬅️ make sure you have this page

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  bool _isAdmin = false;
  bool _isPastor = false;
  bool _isLeader = false;
  final Set<String> _leaderMinistriesByName = {};

  StreamController<List<Map<String, dynamic>>>? _mergedCtrl;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subForYou;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subLeader;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;

  List<Map<String, dynamic>> _bufForYou = const [];
  List<Map<String, dynamic>> _bufLeader = const [];
  String _combineKey = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _subForYou?.cancel();
    _subLeader?.cancel();
    _mergedCtrl?.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final user = _auth.currentUser;
    if (user == null) return;
    _uid = user.uid;

    _userSub = _db.collection('users').doc(user.uid).snapshots().listen((snap) async {
      final data = snap.data() ?? {};
      final roles = (data['roles'] is List)
          ? List<String>.from((data['roles'] as List).map((e) => e.toString().toLowerCase()))
          : <String>[];

      bool isAdmin = roles.contains('admin') || data['isAdmin'] == true;
      bool isPastor = roles.contains('pastor') || data['isPastor'] == true;

      final lmUser = (data['leadershipMinistries'] is List)
          ? List<String>.from((data['leadershipMinistries'] as List).map((e) => e.toString()))
          : <String>[];

      final memberId = (data['memberId'] ?? '').toString();
      final leaderNames = <String>{...lmUser.map((e) => e.trim()).where((e) => e.isNotEmpty)};
      if (memberId.isNotEmpty) {
        try {
          final mem = await _db.collection('members').doc(memberId).get();
          final md = mem.data() ?? {};
          if (md['leadershipMinistries'] is List) {
            leaderNames.addAll(
              List.from(md['leadershipMinistries'])
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty),
            );
          }
          if (md['isPastor'] == true) isPastor = true;
          final mRoles = (md['roles'] is List)
              ? List<String>.from((md['roles'] as List).map((e) => e.toString().toLowerCase()))
              : <String>[];
          if (mRoles.contains('admin')) isAdmin = true;
          if (mRoles.contains('pastor')) isPastor = true;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _isAdmin = isAdmin;
        _isPastor = isPastor;
        _isLeader = leaderNames.isNotEmpty || roles.contains('leader') || data['isLeader'] == true;
        _leaderMinistriesByName
          ..clear()
          ..addAll(leaderNames);
      });

      _startCombinedStreams();
    });
  }

  // ------------------- Combined Notification Stream -------------------

  void _startCombinedStreams() {
    _mergedCtrl?.close();
    _mergedCtrl = StreamController<List<Map<String, dynamic>>>.broadcast();

    // Direct (For You)
    _subForYou = _db
        .collection('notifications')
        .where('recipientUid', isEqualTo: _uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((qs) {
      _bufForYou = qs.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      _emitMerged();
    });

    // Leader Broadcasts
    if (_isAdmin || _isLeader || _isPastor) {
      _subLeader = _db
          .collection('notifications')
          .where('audience.leadersOnly', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen((qs) {
        _bufLeader = qs.docs
            .map((d) => {'id': d.id, ...d.data()})
            .where((n) {
          final type = (n['type'] ?? '').toString();
          if (type != 'join_request' && type != 'join_request_cancelled') return false;
          final acks = (n['acks'] is Map) ? Map<String, dynamic>.from(n['acks']) : const {};
          if (_uid != null && acks[_uid] == true) return false;
          if (_isAdmin || _isPastor) return true;
          final name = (n['ministryId'] ?? '').toString();
          return _leaderMinistriesByName.contains(name);
        })
            .toList();
        _emitMerged();
      });
    }
  }

  void _emitMerged() {
    if (_mergedCtrl == null) return;
    final all = <Map<String, dynamic>>[..._bufForYou, ..._bufLeader];
    all.sort((a, b) {
      final ta = a['createdAt'];
      final tb = b['createdAt'];
      final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
      final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
      return db.compareTo(da);
    });
    _mergedCtrl!.add(all);
  }

  Stream<List<Map<String, dynamic>>> get _notificationsStream =>
      _mergedCtrl?.stream ?? const Stream.empty();

  // ------------------- Helpers -------------------

  Future<void> _markReadAndRemove(Map<String, dynamic> n) async {
    final id = (n['id'] ?? '').toString();
    if (id.isEmpty) return;
    final ref = _db.collection('notifications').doc(id);
    final recipientUid = (n['recipientUid'] ?? '').toString();
    final isDirect = recipientUid.isNotEmpty && _uid == recipientUid;
    try {
      await ref.set({'read': true}, SetOptions(merge: true));
      if (isDirect) {
        await ref.delete();
      } else if (_uid != null) {
        await ref.set({'acks': {_uid!: true}}, SetOptions(merge: true));
      }
    } catch (_) {}
  }

  String _fmtWhen(dynamic ts) {
    final dt = (ts is Timestamp) ? ts.toDate() : null;
    if (dt == null) return '—';
    return DateFormat('dd MMM, HH:mm').format(dt.toLocal());
  }

  String _titleFor(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();
    switch (type) {
      case 'join_request':
        return 'New join request';
      case 'join_request_result':
        final r = (n['result'] ?? '').toString();
        return r == 'approved'
            ? 'Your join request was approved'
            : 'Your join request was declined';
      case 'join_request_cancelled':
        return 'Join request cancelled';
      case 'ministry_request_created':
        return 'New ministry creation request';
      case 'ministry_request_result':
        final r = (n['result'] ?? '').toString();
        return r == 'approved'
            ? 'Your ministry was approved'
            : 'Your ministry was declined';
      case 'prayer_request_created':
        return 'New prayer request';
      default:
        return 'Notification';
    }
  }

  String _subtitleFor(Map<String, dynamic> n) {
    final name = (n['ministryName'] ?? n['ministryId'] ?? '').toString();
    final when = _fmtWhen(n['createdAt']);
    return name.isEmpty ? when : '$name • $when';
  }

  Icon _iconFor(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();
    switch (type) {
      case 'join_request':
        return const Icon(Icons.group_add);
      case 'join_request_result':
        return const Icon(Icons.check_circle);
      case 'join_request_cancelled':
        return const Icon(Icons.undo);
      case 'ministry_request_created':
        return const Icon(Icons.pending_actions);
      case 'ministry_request_result':
        return const Icon(Icons.verified);
      case 'prayer_request_created':
        return const Icon(Icons.volunteer_activism);
      default:
        return const Icon(Icons.notifications);
    }
  }

  // ------------------- Navigation -------------------

  Future<void> _openFrom(Map<String, dynamic> n) async {
    final type = (n['type'] ?? '').toString();
    final ministryDocId = (n['ministryDocId'] ?? '').toString();
    final ministryName = (n['ministryName'] ?? n['ministryId'] ?? '').toString();

    bool opened = false;

    // ✅ NEW: If pastor taps "join_request", go to PastorJoinRequestsPage
    if (type == 'join_request' && _isPastor) {
      opened = true;
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PastorMinistryApprovalsPage()),
        );
      }
    }

    // Ministry-related (normal users/leaders)
    if (!opened &&
        (type.startsWith('join_request') ||
            type == 'join_request_result' ||
            type == 'ministry_request_result')) {
      if (ministryName.isNotEmpty || ministryDocId.isNotEmpty) {
        opened = true;
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MinistryDetailsPage(
                ministryId:
                ministryDocId.isNotEmpty ? ministryDocId : 'unknown',
                ministryName:
                ministryName.isNotEmpty ? ministryName : '(Unknown Ministry)',
              ),
            ),
          );
        }
      }
    }

    // fallback for prayer/ministry creation
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification opened.')),
      );
    }

    await _markReadAndRemove(n);
  }

  Widget _tile(Map<String, dynamic> n) {
    final icon = _iconFor(n);
    final title = _titleFor(n);
    final subtitle = _subtitleFor(n);

    return ListTile(
      leading: icon,
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => _openFrom(n),
      trailing: OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open'),
        onPressed: () => _openFrom(n),
      ),
    );
  }

  // ------------------- Build -------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _notificationsStream,
        builder: (context, snap) {
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('No notifications.'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 0),
            itemBuilder: (_, i) => _tile(items[i]),
          );
        },
      ),
    );
  }
}
