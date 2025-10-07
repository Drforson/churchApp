// lib/pages/ministry_details_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/firestore_paths.dart';
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

  Map<String, dynamic>? _currentUserData;
  bool _loadingUser = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this); // Members / Feed / Overview
    _fetchCurrentUser();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _fetchCurrentUser() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setState(() {
          _loadingUser = false;
          _currentUserData = null;
        });
        return;
      }
      final snap = await FirebaseFirestore.instance.collection(FP.users).doc(uid).get();
      final data = snap.data() ?? {};
      final roles = (data['roles'] is List)
          ? List<String>.from(data['roles'])
          : <String>[];
      final leadershipMinistries = (data['leadershipMinistries'] is List)
          ? List<String>.from(data['leadershipMinistries'])
          : <String>[];

      setState(() {
        _currentUserData = {
          'roles': roles,
          'leadershipMinistries': leadershipMinistries,
        };
        _loadingUser = false;
      });
    } catch (_) {
      setState(() {
        _loadingUser = false;
        _currentUserData = null;
      });
    }
  }

  bool _isAdmin() {
    if (_currentUserData == null) return false;
    final roles = List<String>.from(_currentUserData!['roles'] ?? const <String>[]);
    return roles.contains('admin');
  }

  bool _isAdminOrLeaderOfThisMinistry() {
    if (_currentUserData == null) return false;
    final roles = List<String>.from(_currentUserData!['roles'] ?? const <String>[]);
    final leadershipMinistries =
    List<String>.from(_currentUserData!['leadershipMinistries'] ?? const <String>[]);
    return roles.contains('admin') ||
        (roles.contains('leader') && leadershipMinistries.contains(widget.ministryName));
  }

  Future<String?> _getUserIdByMemberId(String memberId) async {
    final qs = await FirebaseFirestore.instance
        .collection(FP.users)
        .where('memberId', isEqualTo: memberId)
        .limit(1)
        .get();
    if (qs.docs.isEmpty) return null;
    return qs.docs.first.id;
  }

  // ===================== Leader Promotion / Demotion (no writes to users.roles) =====================

  final Set<String> _processingMembers = {};

  Future<void> _promoteToLeader(String memberId) async {
    if (!_isAdminOrLeaderOfThisMinistry()) return;
    setState(() => _processingMembers.add(memberId));
    try {
      final db = FirebaseFirestore.instance;
      final memberRef = db.collection(FP.members).doc(memberId);

      // link to user doc if exists
      final userId = await _getUserIdByMemberId(memberId);
      final userRef = (userId != null) ? db.collection(FP.users).doc(userId) : null;

      final batch = db.batch();
      batch.update(memberRef, {
        'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
      });
      if (userRef != null) {
        batch.update(userRef, {
          // intentionally NOT touching users.roles
          'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
        });
      }
      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Promoted to leader.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error promoting: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _processingMembers.remove(memberId));
    }
  }

  Future<void> _demoteFromLeader(String memberId) async {
    if (!_isAdminOrLeaderOfThisMinistry()) return;
    setState(() => _processingMembers.add(memberId));
    try {
      final db = FirebaseFirestore.instance;
      final memberRef = db.collection(FP.members).doc(memberId);

      final userId = await _getUserIdByMemberId(memberId);
      final userRef = (userId != null) ? db.collection(FP.users).doc(userId) : null;

      final batch = db.batch();
      batch.update(memberRef, {
        'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
      });
      if (userRef != null) {
        batch.update(userRef, {
          // intentionally NOT touching users.roles
          'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
        });
      }
      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demoted from leader.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error demoting: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _processingMembers.remove(memberId));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingUser) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Members'),
            Tab(text: 'Feed'),
            Tab(text: 'Overview'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(
            ministryName: widget.ministryName,
            ministryId: widget.ministryId,
            canModerate: _isAdminOrLeaderOfThisMinistry(),
            isAdmin: _isAdmin(),
            processingMembers: _processingMembers,
            onPromote: _promoteToLeader,
            onDemote: _demoteFromLeader,
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

// =====================================================================================
// Members Tab (debounced search, join-request panel, promote/demote without full refresh)
// =====================================================================================

class _MembersTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  final bool canModerate;
  final bool isAdmin;
  final Set<String> processingMembers;
  final Future<void> Function(String memberId) onPromote;
  final Future<void> Function(String memberId) onDemote;

  const _MembersTab({
    required this.ministryId,
    required this.ministryName,
    required this.canModerate,
    required this.isAdmin,
    required this.processingMembers,
    required this.onPromote,
    required this.onDemote,
  });

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _db = FirebaseFirestore.instance;

  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _filter = '';
  String _roleFilter = 'All'; // All / Leaders / Members
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    // Debounce so typing is smooth and we don't rebuild on every keystroke
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _filter = _searchCtrl.text.trim().toLowerCase();
      });
    });
  }

  bool _matchSearchAndRole(Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString().toLowerCase();
    final email = (m['email'] ?? '').toString().toLowerCase();
    final isLeader = (m['isLeader'] == true);
    final hit = _filter.isEmpty || name.contains(_filter) || email.contains(_filter);

    if (!hit) return false;
    if (_roleFilter == 'Leaders') return isLeader;
    if (_roleFilter == 'Members') return !isLeader;
    return true;
  }

  Stream<List<Map<String, dynamic>>> _membersStream() {
    // We query members who either are in this ministry (members tab focus)
    // NOTE: We keep the query simple and filter in memory for smoother UX.
    return _db
        .collection(FP.members)
        .where('ministries', arrayContains: widget.ministryName)
        .snapshots()
        .map((snap) {
      return snap.docs.map((d) {
        final data = d.data();
        final first = (data['firstName'] ?? '').toString();
        final last = (data['lastName'] ?? '').toString();
        final name = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        final email = (data['email'] ?? '').toString();
        final leadership = List<String>.from(data['leadershipMinistries'] ?? const <String>[]);
        final isLeaderHere = leadership.contains(widget.ministryName);
        return {
          'memberId': d.id,
          'name': name.isEmpty ? 'Unnamed Member' : name,
          'email': email,
          'isLeader': isLeaderHere,
          'leadershipMinistries': leadership,
        };
      }).toList();
    });
  }

  // ---------- Join Requests for this ministry ----------
  Stream<List<Map<String, dynamic>>> _joinRequestsStream() {
    return _db
        .collection(FP.joinRequests)
        .where('ministryId', isEqualTo: widget.ministryName)
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .asyncMap((qs) async {
      final out = <Map<String, dynamic>>[];
      for (final doc in qs.docs) {
        final data = doc.data();
        final memberId = (data['memberId'] ?? '').toString();
        final requestedAt = (data['requestedAt'] is Timestamp)
            ? (data['requestedAt'] as Timestamp).toDate()
            : null;

        String fullName = 'Unknown Member';
        if (memberId.isNotEmpty) {
          final mem = await _db.collection(FP.members).doc(memberId).get();
          if (mem.exists) {
            final md = mem.data()!;
            final fn = (md['firstName'] ?? '').toString();
            final ln = (md['lastName'] ?? '').toString();
            final nm = ('$fn $ln').trim();
            if (nm.isNotEmpty) fullName = nm;
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

  Future<void> _approveJoin(String requestId, String memberId) async {
    if (!widget.canModerate) return;
    try {
      final db = _db;
      final jrRef = db.collection(FP.joinRequests).doc(requestId);
      final memberRef = db.collection(FP.members).doc(memberId);

      await db.runTransaction((tx) async {
        final jrSnap = await tx.get(jrRef);
        if (!jrSnap.exists) throw Exception('Join request not found');
        final r = jrSnap.data() as Map<String, dynamic>;
        final status = (r['status'] ?? '').toString();
        final ministryName = (r['ministryId'] ?? '').toString();
        if (status != 'pending') throw Exception('Request already processed');
        if (ministryName != widget.ministryName) {
          throw Exception('Request belongs to another ministry');
        }

        final memSnap = await tx.get(memberRef);
        if (!memSnap.exists) throw Exception('Member not found');
        final md = memSnap.data() as Map<String, dynamic>;
        final current = List<String>.from(md['ministries'] ?? const <String>[]);
        if (!current.contains(widget.ministryName)) {
          tx.update(memberRef, {
            'ministries': FieldValue.arrayUnion([widget.ministryName]),
          });
        }

        tx.update(jrRef, {
          'status': 'approved',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request approved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error approving: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _rejectJoin(String requestId) async {
    if (!widget.canModerate) return;
    try {
      await _db.collection(FP.joinRequests).doc(requestId).update({
        'status': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request rejected')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error rejecting: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // ---------- Search + Filter row ----------
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search members by name or email…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _roleFilter,
                onChanged: (v) => setState(() => _roleFilter = v ?? 'All'),
                items: const [
                  DropdownMenuItem(value: 'All', child: Text('All')),
                  DropdownMenuItem(value: 'Leaders', child: Text('Leaders')),
                  DropdownMenuItem(value: 'Members', child: Text('Members')),
                ],
              ),
            ],
          ),
        ),

        // ---------- Pending join requests (leaders/admins only) ----------
        if (widget.canModerate)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Pending Join Requests',
                  style: theme.textTheme.titleMedium),
            ),
          ),
        if (widget.canModerate)
          SizedBox(
            height: 120,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _joinRequestsStream(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final reqs = snap.data!;
                if (reqs.isEmpty) {
                  return const Center(child: Text('No pending requests.'));
                }
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: reqs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final r = reqs[i];
                    final ts = r['requestedAt'] as DateTime?;
                    final when = ts != null
                        ? DateFormat('dd MMM, HH:mm').format(ts)
                        : '—';
                    return SizedBox(
                      width: 280,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r['fullName'] ?? 'Unknown',
                                  style: theme.textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text('Member: ${r['memberId']}',
                                  style: theme.textTheme.bodySmall),
                              Text('Requested: $when',
                                  style: theme.textTheme.bodySmall),
                              const Spacer(),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => _rejectJoin(r['id']),
                                    icon: const Icon(Icons.cancel),
                                    label: const Text('Reject'),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        _approveJoin(r['id'], r['memberId']),
                                    icon: const Icon(Icons.check_circle),
                                    label: const Text('Approve'),
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

        // ---------- Members list ----------
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              // local filter only (fast, avoids requery)
              final all = snap.data!;
              final filtered = all.where(_matchSearchAndRole).toList();

              if (filtered.isEmpty) {
                return const Center(child: Text('No members found.'));
              }

              return ListView.separated(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final m = filtered[i];
                  final memberId = m['memberId'] as String;
                  final isLeader = m['isLeader'] == true;
                  final busy = widget.processingMembers.contains(memberId);

                  return Card(
                    child: ListTile(
                      title: Text(m['name'] ?? 'Unnamed Member'),
                      subtitle: Text(m['email'] ?? ''),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.canModerate) ...[
                            Tooltip(
                              message: isLeader
                                  ? 'Demote from leader'
                                  : 'Promote to leader',
                              child: IgnorePointer(
                                ignoring: busy,
                                child: Switch(
                                  value: isLeader,
                                  onChanged: (val) {
                                    if (val) {
                                      widget.onPromote(memberId);
                                    } else {
                                      widget.onDemote(memberId);
                                    }
                                  },
                                ),
                              ),
                            ),
                            if (busy)
                              const Padding(
                                padding: EdgeInsets.only(left: 8.0),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                          ],
                        ],
                      ),
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

// ===========================
// Overview tab (simple stats)
// ===========================

class _OverviewTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _OverviewTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    final membersQ = db
        .collection(FP.members)
        .where('ministries', arrayContains: ministryName);

    final leadersQ = db
        .collection(FP.members)
        .where('leadershipMinistries', arrayContains: ministryName);

    final postsQ = db
        .collection(FP.ministries)
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
