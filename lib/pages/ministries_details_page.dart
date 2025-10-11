// lib/pages/ministries_details_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/firestore_paths.dart'; // keep if you use FP.* elsewhere
import 'ministry_feed_page.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // ministries/{docId}
  final String ministryName; // human-readable name used across membership arrays

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage>
    with TickerProviderStateMixin {
  late final TabController _tab;

  bool _loading = true;
  String? _uid;
  String? _memberId;
  Set<String> _roles = {};
  Set<String> _memberMinistriesByName = {};
  String? _latestJoinStatus; // pending / approved / rejected / null
  bool _canAccess = false;   // computed gate

  final _db = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this); // Members / Feed / Overview
    _bootstrap();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final auth = FirebaseAuth.instance;
      _uid = auth.currentUser?.uid;

      if (_uid == null) {
        setState(() { _loading = false; _canAccess = false; });
        return;
      }

      final userSnap = await _db.collection('users').doc(_uid).get();
      final u = userSnap.data() ?? {};
      _memberId = (u['memberId'] is String) ? u['memberId'] as String : null;
      _roles = (u['roles'] is List) ? Set<String>.from(u['roles']) : <String>{};

      if (_memberId != null) {
        final memSnap = await _db.collection('members').doc(_memberId).get();
        final m = memSnap.data() ?? {};
        _memberMinistriesByName =
        (m['ministries'] is List) ? Set<String>.from(m['ministries']) : <String>{};
      }

      final rolesLower = _roles.map((e) => e.toLowerCase()).toSet();
      final isAdmin = rolesLower.contains('admin');
      final isPastor = rolesLower.contains('pastor');
      final isMemberHere = _memberMinistriesByName.contains(widget.ministryName);
      _canAccess = isAdmin || isPastor || isMemberHere;

      // latest request status (for banner)
      if (_memberId != null) {
        final q = await _db.collection('join_requests')
            .where('memberId', isEqualTo: _memberId)
            .where('ministryId', isEqualTo: widget.ministryName) // NAME
            .orderBy('requestedAt', descending: true)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          _latestJoinStatus = (q.docs.first.data()['status'] as String?)?.toLowerCase();
        }
      }

      setState(() => _loading = false);
    } catch (_) {
      setState(() { _loading = false; _canAccess = false; });
    }
  }

  /// Notify the requester (stored under /notifications)
  Future<void> _notifyRequester(
      String requesterMemberId,
      String joinRequestId,
      String result,
      ) async {
    // Resolve requester uid
    String? requesterUid;
    final qs = await _db.collection('users')
        .where('memberId', isEqualTo: requesterMemberId)
        .limit(1).get();
    if (qs.docs.isNotEmpty) requesterUid = qs.docs.first.id;

    await _db.collection('notifications').add({
      'type': 'join_request_result',
      'ministryId': widget.ministryName,
      'ministryDocId': widget.ministryId,
      'memberId': requesterMemberId,
      'joinRequestId': joinRequestId,
      'result': result, // approved | rejected
      if (requesterUid != null) 'recipientUid': requesterUid,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ===== Moderation actions (called from Members tab panel) =====
  Future<void> approveJoin(String requestId, String memberId) async {
    try {
      final jrRef = _db.collection('join_requests').doc(requestId);
      final memberRef = _db.collection('members').doc(memberId);

      await _db.runTransaction((tx) async {
        final jrSnap = await tx.get(jrRef);
        if (!jrSnap.exists) throw Exception('Join request not found');
        final r = jrSnap.data() as Map<String, dynamic>;
        final status = (r['status'] ?? '').toString();
        if (status != 'pending') throw Exception('Request already processed');
        final ministryName = (r['ministryId'] ?? '').toString();
        if (ministryName != widget.ministryName) throw Exception('Wrong ministry');

        final memSnap = await tx.get(memberRef);
        if (!memSnap.exists) throw Exception('Member not found');
        final md = memSnap.data() as Map<String, dynamic>;
        final current = List<String>.from(md['ministries'] ?? const <String>[]);
        if (!current.contains(widget.ministryName)) {
          tx.update(memberRef, {'ministries': FieldValue.arrayUnion([widget.ministryName])});
        }

        tx.update(jrRef, {'status': 'approved', 'updatedAt': FieldValue.serverTimestamp()});
      });

      await _notifyRequester(memberId, requestId, 'approved');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request approved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error approving: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> rejectJoin(String requestId, String memberId) async {
    try {
      await _db.collection('join_requests').doc(requestId).update({
        'status': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _notifyRequester(memberId, requestId, 'rejected');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request rejected')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error rejecting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_canAccess) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.ministryName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 12),
                const Text(
                  "You don't have access to this ministry yet.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                if (_latestJoinStatus == 'pending')
                  const Text(
                    'Your join request is pending approval.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: 'Members'), Tab(text: 'Feed'), Tab(text: 'Overview')],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(
            ministryId: widget.ministryId,
            ministryName: widget.ministryName,
            onApprove: approveJoin,
            onReject: rejectJoin,
          ),
          MinistryFeedPage(
            ministryId: widget.ministryId,
            ministryName: widget.ministryName,
          ),
          _OverviewTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
        ],
      ),
    );
  }
}

// ===== Members tab: includes Pending Join Requests panel for leaders/admins only =====

class _MembersTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  final Future<void> Function(String requestId, String memberId) onApprove;
  final Future<void> Function(String requestId, String memberId) onReject;

  const _MembersTab({
    required this.ministryId,
    required this.ministryName,
    required this.onApprove,
    required this.onReject,
  });

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _db = FirebaseFirestore.instance;

  bool _isLeaderOrAdmin = false;

  @override
  void initState() {
    super.initState();
    _resolveCanModerate();
  }

  Future<void> _resolveCanModerate() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final u = await _db.collection('users').doc(uid).get();
    final data = u.data() ?? {};
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : <String>[];
    final leaderMins = (data['leadershipMinistries'] is List)
        ? List<String>.from(data['leadershipMinistries'])
        : <String>[];
    final can = roles.map((e) => e.toLowerCase()).contains('admin') ||
        (roles.map((e) => e.toLowerCase()).contains('leader') &&
            leaderMins.contains(widget.ministryName));
    if (mounted) setState(() => _isLeaderOrAdmin = can);
  }

  Stream<List<Map<String, dynamic>>> _membersStream() {
    return _db
        .collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .snapshots()
        .map((snap) {
      return snap.docs.map((d) {
        final data = d.data();
        final first = (data['firstName'] ?? '').toString();
        final last = (data['lastName'] ?? '').toString();
        final name = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        final email = (data['email'] ?? '').toString();
        return {
          'memberId': d.id,
          'name': name.isEmpty ? 'Unnamed Member' : name,
          'email': email,
        };
      }).toList();
    });
  }

  Stream<List<Map<String, dynamic>>> _pendingRequests() {
    return _db
        .collection('join_requests')
        .where('ministryId', isEqualTo: widget.ministryName)
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .asyncMap((qs) async {
      final out = <Map<String, dynamic>>[];
      for (final doc in qs.docs) {
        final r = doc.data();
        final memberId = (r['memberId'] ?? '').toString();
        final requestedAt = (r['requestedAt'] is Timestamp)
            ? (r['requestedAt'] as Timestamp).toDate()
            : null;

        // Resolve full name now (so we show a human name, not the uid)
        String fullName = 'Unknown Member';
        if (memberId.isNotEmpty) {
          final m = await _db.collection('members').doc(memberId).get();
          if (m.exists) {
            final md = m.data()!;
            final fn = (md['firstName'] ?? '').toString();
            final ln = (md['lastName'] ?? '').toString();
            final fl = ('$fn $ln').trim();
            fullName = (md['fullName'] is String && (md['fullName'] as String).trim().isNotEmpty)
                ? (md['fullName'] as String).trim()
                : (fl.isNotEmpty ? fl : fullName);
          }
        }

        out.add({
          'id': doc.id,
          'memberId': memberId,
          'fullName': fullName,
          'requestedAt': requestedAt,
        });
      }
      return out;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isLeaderOrAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Pending Join Requests',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
        if (_isLeaderOrAdmin)
          SizedBox(
            height: 130,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _pendingRequests(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final reqs = snap.data!;
                if (reqs.isEmpty) return const Center(child: Text('No pending requests.'));
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: reqs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final r = reqs[i];
                    final when = (r['requestedAt'] is DateTime)
                        ? DateFormat('dd MMM, HH:mm').format(r['requestedAt'] as DateTime)
                        : '—';

                    return SizedBox(
                      width: 300,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Full name (not uid)
                              Text(
                                r['fullName'] ?? 'Unknown Member',
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              // Show memberId very subtly below, if you want to keep it.
                              Text(
                                'ID: ${r['memberId']}',
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Requested: $when',
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const Spacer(),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  // RED X (reject)
                                  IconButton(
                                    tooltip: 'Reject',
                                    onPressed: () =>
                                        widget.onReject(r['id'], r['memberId']),
                                    icon: const Icon(Icons.close),
                                    color: Colors.red,
                                  ),
                                  const SizedBox(width: 6),
                                  // GREEN CHECK (approve)
                                  IconButton(
                                    tooltip: 'Approve',
                                    onPressed: () =>
                                        widget.onApprove(r['id'], r['memberId']),
                                    icon: const Icon(Icons.check_circle),
                                    color: Colors.green,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final members = snap.data!;
              if (members.isEmpty) return const Center(child: Text('No members yet.'));
              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: members.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final m = members[i];
                  return Card(
                    child: ListTile(
                      title: Text(m['name'] ?? 'Unnamed Member'),
                      subtitle: Text(m['email'] ?? ''),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _OverviewTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    final membersQ =
    db.collection('members').where('ministries', arrayContains: ministryName);
    final leadersQ =
    db.collection('members').where('leadershipMinistries', arrayContains: ministryName);
    final postsQ = db
        .collection('ministries')
        .doc(ministryId)
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .limit(5);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          FutureBuilder<QuerySnapshot>(
            future: membersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Members', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: leadersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Leaders', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Recent Posts', style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot>(
            stream: postsQ.snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Text('No posts yet.');
              }
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final title = (data['title'] ?? 'Untitled').toString();
                  final createdAt = (data['createdAt'] is Timestamp)
                      ? (data['createdAt'] as Timestamp).toDate()
                      : null;
                  final when = createdAt != null
                      ? DateFormat('dd MMM yyyy, HH:mm').format(createdAt)
                      : '—';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.article),
                    title: Text(title),
                    subtitle: Text('Posted: $when'),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Text(label, style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(value, style: theme.textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
