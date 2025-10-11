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

  String? _uid;
  String? _memberId;
  Set<String> _userRoles = {};
  Set<String> _memberMinistriesByName = {};
  String? _latestJoinStatus; // pending / approved / rejected / null

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
    await _fetchCurrentUser();
    await _fetchMembershipAndStatus();
  }

  Future<void> _fetchCurrentUser() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setState(() {
          _loadingUser = false;
          _currentUserData = null;
          _uid = null;
          _memberId = null;
          _userRoles = {};
        });
        return;
      }
      final userSnap = await FirebaseFirestore.instance.collection(FP.users).doc(uid).get();
      final data = userSnap.data() ?? {};

      final roles = (data['roles'] is List)
          ? List<String>.from(data['roles'])
          : <String>[];
      final leadershipMinistries = (data['leadershipMinistries'] is List)
          ? List<String>.from(data['leadershipMinistries'])
          : <String>[];
      final memberId = (data['memberId'] is String) ? data['memberId'] as String : null;

      Set<String> ministriesByName = {};
      if (memberId != null) {
        final mem = await FirebaseFirestore.instance.collection(FP.members).doc(memberId).get();
        final m = mem.data() ?? {};
        ministriesByName = (m['ministries'] is List) ? Set<String>.from(m['ministries']) : <String>{};
      }

      setState(() {
        _uid = uid;
        _memberId = memberId;
        _userRoles = roles.toSet();
        _memberMinistriesByName = ministriesByName;
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

  Future<void> _fetchMembershipAndStatus() async {
    try {
      if (_memberId == null) {
        setState(() => _latestJoinStatus = null);
        return;
      }
      final q = await FirebaseFirestore.instance
          .collection(FP.joinRequests)
          .where('memberId', isEqualTo: _memberId)
      // Use ministry *name* in join_requests, to match your schema
          .where('ministryId', isEqualTo: widget.ministryName)
          .orderBy('requestedAt', descending: true)
          .limit(1)
          .get();

      String? status;
      if (q.docs.isNotEmpty) {
        status = (q.docs.first.data()['status'] as String?)?.toLowerCase();
      }
      setState(() {
        _latestJoinStatus = status; // pending / approved / rejected / null
      });
    } catch (_) {}
  }

  bool _isAdmin() {
    final r = _userRoles.map((e) => e.toLowerCase()).toSet();
    return r.contains('admin');
  }

  bool _isPastor() {
    final r = _userRoles.map((e) => e.toLowerCase()).toSet();
    return r.contains('pastor');
  }

  bool _isLeaderHere() {
    if (_currentUserData == null) return false;
    final roles = List<String>.from(_currentUserData!['roles'] ?? const <String>[]);
    final leadershipMinistries =
    List<String>.from(_currentUserData!['leadershipMinistries'] ?? const <String>[]);
    return roles.contains('leader') && leadershipMinistries.contains(widget.ministryName);
  }

  bool _isAdminOrLeaderOfThisMinistry() {
    return _isAdmin() || _isLeaderHere();
  }

  bool _amMemberOfThisMinistry() {
    return _memberMinistriesByName.contains(widget.ministryName);
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

  Future<void> _openJoinBottomSheet() async {
    if (_uid == null || _memberId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to request to join.')),
      );
      return;
    }

    final controller = TextEditingController();
    String urgency = 'normal';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final insets = MediaQuery.of(ctx).viewInsets;
        return Padding(
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.group_add),
                title: Text('Request to join ${widget.ministryName}', style: Theme.of(ctx).textTheme.titleMedium),
                subtitle: const Text('This will notify ministry leaders for approval.'),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: controller,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Why do you want to join? (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Urgency:'),
                        const SizedBox(width: 12),
                        StatefulBuilder(
                          builder: (ctx2, setSB) => Row(
                            children: [
                              ChoiceChip(
                                label: const Text('Normal'),
                                selected: urgency == 'normal',
                                onSelected: (_) => setSB(() => urgency = 'normal'),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: const Text('High'),
                                selected: urgency == 'high',
                                onSelected: (_) => setSB(() => urgency = 'high'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.send),
                        label: const Text('Send request'),
                        onPressed: () => Navigator.of(ctx).pop(true),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (ok != true) return;

    try {
      await FirebaseFirestore.instance.collection(FP.joinRequests).add({
        'memberId': _memberId,
        'ministryId': widget.ministryName, // NAME for consistency
        'requestedByUid': _uid,
        'message': controller.text.trim().isEmpty ? null : controller.text.trim(),
        'urgency': 'normal',
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });
      await _fetchMembershipAndStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_outline),
                SizedBox(width: 8),
                Expanded(child: Text('Join request sent. You’ll be notified when approved.')),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send request: $e')),
        );
      }
    }
  }

  // Promotion / demotion logic (unchanged)
  final Set<String> _processingMembers = {};

  Future<void> _promoteToLeader(String memberId) async {
    if (!_isAdminOrLeaderOfThisMinistry()) return;
    setState(() => _processingMembers.add(memberId));
    try {
      final db = FirebaseFirestore.instance;
      final memberRef = db.collection(FP.members).doc(memberId);

      final userId = await _getUserIdByMemberId(memberId);
      final userRef = (userId != null) ? db.collection(FP.users).doc(userId) : null;

      final batch = db.batch();
      batch.update(memberRef, {
        'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
      });
      if (userRef != null) {
        batch.update(userRef, {
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

    final canSeeJoin =
        !_isAdmin() && !_isPastor() && !_amMemberOfThisMinistry() && _uid != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        actions: [
          if (canSeeJoin && _latestJoinStatus != 'pending')
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.group_add),
                label: const Text('Join'),
                onPressed: _openJoinBottomSheet,
              ),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Members'),
            Tab(text: 'Feed'),
            Tab(text: 'Overview'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_latestJoinStatus == 'pending')
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outline),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_top),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Your join request is pending')),
                  TextButton(
                    onPressed: () {},
                    child: const Text('Details'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
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
          ),
        ],
      ),
    );
  }
}

// ===== Members tab & Overview tab widgets remain the same as your previous version =====
// (They don’t affect the Join button visibility logic covered above.)

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
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
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
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

                  return Card(
                    child: ListTile(
                      title: Text(m['name'] ?? 'Unnamed Member'),
                      subtitle: Text(m['email'] ?? ''),
                      trailing: widget.canModerate
                          ? _LeaderToggle(
                        value: isLeader,
                        onChanged: (val) {
                          if (val) {
                            widget.onPromote(memberId);
                          } else {
                            widget.onDemote(memberId);
                          }
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
}

class _LeaderToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _LeaderToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Switch(value: value, onChanged: onChanged);
  }
}

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
