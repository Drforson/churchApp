// lib/pages/ministries_details_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // for HapticFeedback
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
  bool _canAccess = false;   // admin or member of this ministry

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
      setState(() => _loading = true);

      final user = FirebaseAuth.instance.currentUser;
      _uid = user?.uid;

      // If not signed in, no access
      if (_uid == null) {
        setState(() { _loading = false; _canAccess = false; });
        return;
      }

      // Load user doc
      final userSnap = await _db.collection('users').doc(_uid).get();
      final u = userSnap.data() ?? {};
      _memberId = (u['memberId'] ?? '').toString().isNotEmpty ? (u['memberId'] as String) : null;
      final roles = (u['roles'] is List) ? List<String>.from(u['roles']) : const <String>[];
      _roles = roles.map((e) => e.toString().toLowerCase()).toSet();

      // Load member ministries-by-name
      if (_memberId != null) {
        final memSnap = await _db.collection('members').doc(_memberId).get();
        final m = memSnap.data() ?? {};
        _memberMinistriesByName =
        (m['ministries'] is List) ? Set<String>.from(m['ministries']) : <String>{};
      }

      // Decide access: admin OR member of this ministry
      final isAdmin = _roles.contains('admin');
      final isInThisMinistry = _memberMinistriesByName.contains(widget.ministryName);
      _canAccess = isAdmin || isInThisMinistry;

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
    if (qs.docs.isNotEmpty) {
      requesterUid = qs.docs.first.id;
    }

    if (requesterUid == null) return;

    await _db.collection('notifications').add({
      'uid': requesterUid,
      'type': 'join_request.$result',
      'joinRequestId': joinRequestId,
      'ministryName': widget.ministryName,
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
    });
  }

  Future<void> approveJoin(String requestId, String memberId) async {
    try {
      final jrRef = _db.collection('join_requests').doc(requestId);
      final memberRef = _db.collection('members').doc(memberId);

      // verify still pending to avoid racey double taps
      final snap = await jrRef.get();
      if (snap.exists) {
        final status = (snap.data()?['status'] ?? '').toString().toLowerCase();
        if (status != 'pending') throw Exception('Request already processed');
      }

      // add ministry by name to member doc (idempotent)
      await _db.runTransaction((t) async {
        final md = (await t.get(memberRef)).data();
        if (md == null) throw Exception('Member not found');

        final current = List<String>.from(md['ministries'] ?? const <String>[]);
        if (!current.contains(widget.ministryName)) current.add(widget.ministryName);

        t.update(memberRef, {
          'ministries': current,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        // mark request approved
        t.update(jrRef, {
          'status': 'approved',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      // Notify is non-fatal
      try { await _notifyRequester(memberId, requestId, 'approved'); } catch (_) {}

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
      final jrRef = _db.collection('join_requests').doc(requestId);

      // verify still pending to avoid racey double taps
      final snap = await jrRef.get();
      if (snap.exists) {
        final status = (snap.data()?['status'] ?? '').toString().toLowerCase();
        if (status != 'pending') throw Exception('Request already processed');
      }

      await jrRef.update({
        'status': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Notify is non-fatal
      try { await _notifyRequester(memberId, requestId, 'rejected'); } catch (_) {}

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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
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
          _FeedTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
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
  String? _myMemberId;

  // Track which join_request ids are being submitted
  final Set<String> _busy = <String>{};

  // Optimistic hide: ids temporarily removed from the list
  final Set<String> _hidden = <String>{};

  void _setBusy(String id, bool v) {
    if (!mounted) return;
    setState(() { v ? _busy.add(id) : _busy.remove(id); });
  }

  void _setHidden(String id, bool v) {
    if (!mounted) return;
    setState(() { v ? _hidden.add(id) : _hidden.remove(id); });
  }

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
    _myMemberId = (data['memberId'] ?? '').toString().isNotEmpty ? (data['memberId'] as String) : null;
    final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : <String>[];
    final leaderMins = (data['leadershipMinistries'] is List)
        ? List<String>.from(data['leadershipMinistries'])
        : <String>[];
    final rolesLower = roles.map((e) => e.toLowerCase()).toList();
    final can = rolesLower.contains('admin') ||
        (rolesLower.contains('leader') && leaderMins.contains(widget.ministryName));
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
        final leadership = (data['leadershipMinistries'] is List)
            ? List<String>.from(data['leadershipMinistries']) : <String>[];
        final isLeader = leadership.contains(widget.ministryName);
        return {
          'memberId': d.id,
          'name': name.isEmpty ? 'Unnamed Member' : name,
          'email': email,
          'isLeader': isLeader,
        };
      }).toList();
    });
  }

  // Cover legacy join_requests where ministryId saved as name or docId.
  Stream<List<Map<String, dynamic>>> _pendingRequests() {
    return _db
        .collection('join_requests')
        .where('status', isEqualTo: 'pending')
        .where('ministryId', whereIn: [widget.ministryName, widget.ministryId])
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .asyncMap((qs) async {
      final out = <Map<String, dynamic>>[];
      for (final doc in qs.docs) {
        // Skip optimistically hidden ones
        if (_hidden.contains(doc.id)) continue;

        final r = doc.data();
        final memberId = (r['memberId'] ?? '').toString();
        final requestedAt = (r['requestedAt'] is Timestamp)
            ? (r['requestedAt'] as Timestamp).toDate()
            : null;

        // Resolve full name now (so we show a human name, not the uid)
        String fullName = 'Unknown Member';
        if (memberId.isNotEmpty) {
          final m = await _db.collection('members').doc(memberId).get();
          final md = m.data() ?? {};
          final f = (md['firstName'] ?? '').toString();
          final l = (md['lastName'] ?? '').toString();
          final n = [f, l].where((s) => s.isNotEmpty).join(' ').trim();
          if (n.isNotEmpty) fullName = n;
        }

        out.add({
          'id': doc.id,
          'memberId': memberId,
          'name': fullName,
          'requestedAt': requestedAt,
        });
      }
      return out;
    });
  }

  // ===== Member moderation helpers =====

  Future<DocumentReference<Map<String, dynamic>>?> _userRefForMember(String memberId) async {
    final qs = await _db.collection('users').where('memberId', isEqualTo: memberId).limit(1).get();
    if (qs.docs.isEmpty) return null;
    return qs.docs.first.reference;
  }

  Future<int> _countLeadersInMinistry() async {
    final qs = await _db.collection('members').where('leadershipMinistries', arrayContains: widget.ministryName).get();
    return qs.docs.length;
  }

  // ---------- UPDATED: WriteBatch versions (no transactions) ----------

  Future<void> _promoteToLeader(String memberId) async {
    try {
      final memberRef = _db.collection('members').doc(memberId);
      final userRef = await _userRefForMember(memberId);

      final batch = _db.batch();

      // Update member doc (leaders can update members)
      batch.update(memberRef, {
        'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
        'roles': FieldValue.arrayUnion(['leader']),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Update user doc: only leadershipMinistries (rules forbid leaders changing users.roles)
      if (userRef != null) {
        batch.update(userRef, {
          'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Promoted to leader')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error promoting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _demoteFromLeader(String memberId) async {
    try {
      // prevent removing last leader
      final leadersCount = await _countLeadersInMinistry();
      if (leadersCount <= 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot demote the last leader of this ministry'), backgroundColor: Colors.orange),
        );
        return;
      }

      final memberRef = _db.collection('members').doc(memberId);
      final userRef = await _userRefForMember(memberId);

      final batch = _db.batch();

      // Remove this ministry from leadership arrays
      batch.update(memberRef, {
        'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
        // Also remove 'leader' role; if you only want to remove when no leaderships remain,
        // do it via Cloud Function (requires read). For now keep simple as before:
        'roles': FieldValue.arrayRemove(['leader']),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (userRef != null) {
        batch.update(userRef, {
          'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Demoted from leader')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error demoting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _removeFromMinistry(String memberId) async {
    try {
      // if target is a leader here, ensure not last leader
      final mSnap = await _db.collection('members').doc(memberId).get();
      final m = mSnap.data() ?? {};
      final mLeader = (m['leadershipMinistries'] is List) ? List<String>.from(m['leadershipMinistries']) : <String>[];
      final isLeaderHere = mLeader.contains(widget.ministryName);
      if (isLeaderHere) {
        final leadersCount = await _countLeadersInMinistry();
        if (leadersCount <= 1) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot remove the last leader of this ministry'), backgroundColor: Colors.orange),
          );
          return;
        }
      }

      final memberRef = _db.collection('members').doc(memberId);
      final userRef = await _userRefForMember(memberId);

      final batch = _db.batch();

      // Drop membership + leadership from member doc
      batch.update(memberRef, {
        'ministries': FieldValue.arrayRemove([widget.ministryName]),
        'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
        'roles': FieldValue.arrayRemove(['leader']),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Mirror on user doc (no roles write)
      if (userRef != null) {
        batch.update(userRef, {
          'ministries': FieldValue.arrayRemove([widget.ministryName]),
          'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Member removed from ministry')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error removing: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
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
            height: 156,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _pendingRequests(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snap.hasData) {
                  return const Center(child: Text('No pending requests.'));
                }
                final reqs = snap.data!;
                if (reqs.isEmpty) {
                  return const Center(child: Text('No pending requests.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  scrollDirection: Axis.horizontal,
                  itemCount: reqs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final r = reqs[i];
                    final when = (r['requestedAt'] is DateTime)
                        ? DateFormat('dd MMM, HH:mm').format(r['requestedAt'] as DateTime)
                        : '—';
                    final id = r['id'] as String;
                    final name = (r['name'] as String?)?.trim().isNotEmpty == true
                        ? r['name'] as String
                        : 'Unknown Member';
                    final loading = _busy.contains(id);

                    return SizedBox(
                      width: 320,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                child: Text(
                                  _initials(name),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Requested: $when',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (loading)
                                const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                )
                              else
                                Row(
                                  children: [
                                    IconButton(
                                      tooltip: 'Approve',
                                      icon: const Icon(Icons.check_circle),
                                      onPressed: () async {
                                        HapticFeedback.lightImpact();
                                        _setBusy(id, true);
                                        try {
                                          await widget.onApprove(id, r['memberId'] as String);
                                          _setHidden(id, true); // optimistic remove
                                        } catch (e) {
                                          _setBusy(id, false);
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Approve failed: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        } finally {
                                          _setBusy(id, false);
                                        }
                                      },
                                      color: Colors.green,
                                    ),
                                    IconButton(
                                      tooltip: 'Reject',
                                      icon: const Icon(Icons.cancel),
                                      onPressed: () async {
                                        HapticFeedback.lightImpact();
                                        _setBusy(id, true);
                                        try {
                                          await widget.onReject(id, r['memberId'] as String);
                                          _setHidden(id, true); // optimistic remove
                                        } catch (e) {
                                          _setBusy(id, false);
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Reject failed: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        } finally {
                                          _setBusy(id, false);
                                        }
                                      },
                                      color: Colors.red,
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

        // === Members list
        const SizedBox(height: 12),
        SizedBox(
          height: 520,
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
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              m['name'] ?? 'Unnamed Member',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if ((m['isLeader'] ?? false) == true)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.star_rounded,
                                size: 20,
                                color: Colors.amberAccent, // gold star for leader
                              ),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        m['email'] ?? '',
                        style: const TextStyle(color: Colors.black54),
                      ),
                      trailing: (_isLeaderOrAdmin && (m['memberId'] != _myMemberId))
                          ? PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'promote') {
                            await _promoteToLeader(m['memberId'] as String);
                          } else if (value == 'demote') {
                            await _demoteFromLeader(m['memberId'] as String);
                          } else if (value == 'remove') {
                            await _removeFromMinistry(m['memberId'] as String);
                          }
                        },
                        itemBuilder: (context) {
                          final isLeader = (m['isLeader'] ?? false) == true;
                          return <PopupMenuEntry<String>>[
                            if (!isLeader)
                              const PopupMenuItem<String>(
                                value: 'promote',
                                child: ListTile(
                                  leading: Icon(Icons.arrow_upward),
                                  title: Text('Promote to leader'),
                                ),
                              ),
                            if (isLeader)
                              const PopupMenuItem<String>(
                                value: 'demote',
                                child: ListTile(
                                  leading: Icon(Icons.arrow_downward),
                                  title: Text('Demote from leader'),
                                ),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem<String>(
                              value: 'remove',
                              child: ListTile(
                                leading: Icon(Icons.person_remove),
                                title: Text('Remove from ministry'),
                              ),
                            ),
                          ];
                        },
                      )
                          : null,
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

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts.first.characters.take(1).toString() +
        parts.last.characters.take(1).toString())
        .toUpperCase();
  }
}

class _FeedTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _FeedTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
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
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Recent Posts', style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: postsQ.get(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? const [];
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
                    subtitle: Text(when),
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
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: postsQ.get(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? const [];
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
                    subtitle: Text(when),
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
