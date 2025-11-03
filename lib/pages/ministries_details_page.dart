
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Ministries Details Page
///
/// Tabs:
/// - Members: searchable roster; leaders get moderation tools (promote/demote/remove)
/// - Feed: placeholder (replace with your existing feed UI)
/// - Overview: placeholder (replace with your existing overview UI)
///
/// This page expects Firestore security rules that allow:
///   - members to read other members only if they share a ministry
///   - leaders to update member docs (for leadership/ministry changes)
///   - leaders to update join_requests (approve/reject), per your rules
class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // "ministries/{docId}"
  final String ministryName; // e.g., "Ushering" (must match members.ministries[] value)

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Members', icon: Icon(Icons.group_outlined)),
            Tab(text: 'Feed', icon: Icon(Icons.dynamic_feed_outlined)),
            Tab(text: 'Overview', icon: Icon(Icons.info_outline)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
          const _FeedPlaceholder(),
          const _OverviewPlaceholder(),
        ],
      ),
    );
  }
}

// ===================================================================
// Members Tab (modern UI + leader tools)
// ===================================================================
class _MembersTab extends StatefulWidget {
  final String ministryId;
  final String ministryName;
  const _MembersTab({required this.ministryId, required this.ministryName});

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _searchCtrl = TextEditingController();

  bool _isLeaderHere = false;
  String? _myUid;
  String? _myMemberId;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    _myUid = uid;
    // read users/{uid} to detect leadershipMinistries + memberId
    final userSnap = await _db.collection('users').doc(uid).get();
    final data = userSnap.data() ?? {};
    _myMemberId = data['memberId'] as String?;
    final mins = (data['leadershipMinistries'] is List) ? List<String>.from(data['leadershipMinistries']) : <String>[];
    setState(() {
      _isLeaderHere = mins.map((e) => e.toLowerCase()).contains(widget.ministryName.toLowerCase());
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _membersStream() {
    return _db
        .collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .limit(500)
        .snapshots();
  }

  // Pending join requests for leaders
  Stream<QuerySnapshot<Map<String, dynamic>>> _joinRequestsStream() {
    if (!_isLeaderHere) {
      // dummy stream to avoid switching widgets
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }
    return _db
        .collection('join_requests')
        .where('ministryName', isEqualTo: widget.ministryName)
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .limit(50)
        .snapshots();
  }

  Future<void> _approveJoin(String requestId) async {
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'approved',
      'updatedAt': FieldValue.serverTimestamp(),
      'moderatedByUid': _myUid,
    });
    // Optionally add the ministry to the member doc (often Cloud Functions handle this)
    // We best-effort update here in case no CF exists.
    final jr = await _db.collection('join_requests').doc(requestId).get();
    final memberId = jr.data()?['memberId'];
    if (memberId is String && memberId.isNotEmpty) {
      await _db.collection('members').doc(memberId).update({
        'ministries': FieldValue.arrayUnion([widget.ministryName])
      });
    }
  }

  Future<void> _rejectJoin(String requestId) async {
    await _db.collection('join_requests').doc(requestId).update({
      'status': 'rejected',
      'updatedAt': FieldValue.serverTimestamp(),
      'moderatedByUid': _myUid,
    });
  }

  Future<void> _promoteToLeader(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'leadershipMinistries': FieldValue.arrayUnion([widget.ministryName]),
      'roles': FieldValue.arrayUnion(['leader']),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _demoteLeader(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'leadershipMinistries': FieldValue.arrayRemove([widget.ministryName]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _removeFromMinistry(String memberId) async {
    await _db.collection('members').doc(memberId).update({
      'ministries': FieldValue.arrayRemove([widget.ministryName]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isLeaderHere) _JoinRequestsCard(stream: _joinRequestsStream(), onApprove: _approveJoin, onReject: _rejectJoin),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search members (name, email, phone)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _membersStream(),
            builder: (context, snap) {
              if (snap.hasError) {
                final err = snap.error.toString();
                final isDenied = err.toLowerCase().contains('permission');
                return _ErrorState(
                  title: isDenied ? 'Access restricted' : 'Something went wrong',
                  message: isDenied
                      ? 'You can only view members in ministries you belong to.'
                      : err,
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snap.data!.docs;
              final members = docs.map((d) => _Member.fromMap(d.id, d.data())).toList();
              members.sort((a, b) => (a.fullName ?? '').toLowerCase()
                  .compareTo((b.fullName ?? '').toLowerCase()));

              final q = _searchCtrl.text.trim().toLowerCase();
              final filtered = q.isEmpty
                  ? members
                  : members.where((m) {
                final f = [
                  m.fullName,
                  m.firstName,
                  m.lastName,
                  m.email,
                  m.phoneNumber,
                ].whereType<String>().map((s) => s.toLowerCase()).join(' ');
                return f.contains(q);
              }).toList();

              if (filtered.isEmpty) {
                return const _EmptyState(
                  title: 'No members found',
                  message: 'Try a different search.',
                );
              }

              return RefreshIndicator(
                onRefresh: () async {
                  await _db
                      .collection('members')
                      .where('ministries', arrayContains: widget.ministryName)
                      .limit(1)
                      .get();
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = filtered[i];
                    final isLeaderHere = m.isLeaderOf(widget.ministryName);
                    final isPastor = m.hasRole('pastor') || (m.isPastor ?? false);
                    final isAdmin = m.hasRole('admin');

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      leading: _Avatar(initials: m.initials, photoUrl: m.photoUrl),
                      title: Text(m.fullName ?? 'Unknown',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (m.email != null && m.email!.isNotEmpty) Text(m.email!),
                          if (m.phoneNumber != null && m.phoneNumber!.isNotEmpty) Text(m.phoneNumber!),
                          Wrap(
                            spacing: 8,
                            runSpacing: -6,
                            children: [
                              if (isLeaderHere) const _Chip('Leader'),
                              if (isPastor) const _Chip('Pastor'),
                              if (isAdmin) const _Chip('Admin'),
                            ],
                          )
                        ],
                      ),
                      trailing: _isLeaderHere
                          ? PopupMenuButton<String>(
                        onSelected: (value) async {
                          try {
                            if (value == 'promote') {
                              await _promoteToLeader(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Promoted to leader.')));
                            } else if (value == 'demote') {
                              await _demoteLeader(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Demoted from leader.')));
                            } else if (value == 'remove') {
                              await _removeFromMinistry(m.id);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removed from ministry.')));
                            }
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action failed: $e')));
                          }
                        },
                        itemBuilder: (context) => [
                          if (!isLeaderHere) const PopupMenuItem(value: 'promote', child: Text('Promote to leader')),
                          if (isLeaderHere) const PopupMenuItem(value: 'demote', child: Text('Demote leader')),
                          const PopupMenuItem(value: 'remove', child: Text('Remove from ministry')),
                        ],
                        icon: const Icon(Icons.more_vert),
                      )
                          : null,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// Join Requests card (leaders only)
class _JoinRequestsCard extends StatelessWidget {
  final Stream<QuerySnapshot<Map<String, dynamic>>> stream;
  final Future<void> Function(String requestId) onApprove;
  final Future<void> Function(String requestId) onReject;

  const _JoinRequestsCard({
    required this.stream,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox.shrink();
        }
        final pending = snap.data!.docs;
        if (pending.isEmpty) return const SizedBox.shrink();

        return Card(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.inbox_outlined),
                    const SizedBox(width: 8),
                    Text('Pending Join Requests (${pending.length})',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 8),
                ...pending.map((d) {
                  final data = d.data();
                  final requesterName = (data['memberName'] ?? data['requesterName'] ?? 'Member').toString();
                  final requestedAt = data['requestedAt'];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_add_alt_1_outlined),
                    title: Text(requesterName),
                    subtitle: Text('Request ID: ${d.id}'),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => onReject(d.id),
                          child: const Text('Reject'),
                        ),
                        ElevatedButton(
                          onPressed: () => onApprove(d.id),
                          child: const Text('Approve'),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ===================================================================
// Placeholders for other tabs
// ===================================================================
class _FeedPlaceholder extends StatelessWidget {
  const _FeedPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dynamic_feed_outlined, size: 48),
            const SizedBox(height: 12),
            Text('Ministry Feed', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('Replace this with your existing posts/comments UI.'),
          ],
        ),
      ),
    );
  }
}

class _OverviewPlaceholder extends StatelessWidget {
  const _OverviewPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 48),
            const SizedBox(height: 12),
            Text('Overview', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('Replace this with any ministry details/description.'),
          ],
        ),
      ),
    );
  }
}

// ===================================================================
// Models & UI helpers
// ===================================================================
class _Member {
  final String id;
  final String? firstName;
  final String? lastName;
  final String? fullName;
  final String? email;
  final String? phoneNumber;
  final String? photoUrl;
  final List<dynamic> roles;
  final List<dynamic> leadershipMinistries;
  final List<dynamic> ministries;
  final bool? isPastor;

  _Member({
    required this.id,
    this.firstName,
    this.lastName,
    this.fullName,
    this.email,
    this.phoneNumber,
    this.photoUrl,
    this.roles = const [],
    this.leadershipMinistries = const [],
    this.ministries = const [],
    this.isPastor,
  });

  factory _Member.fromMap(String id, Map<String, dynamic> data) {
    return _Member(
      id: id,
      firstName: data['firstName'] as String?,
      lastName: data['lastName'] as String?,
      fullName: data['fullName'] as String? ?? _composeName(data),
      email: data['email'] as String?,
      phoneNumber: data['phoneNumber'] as String?,
      photoUrl: data['photoUrl'] as String? ?? data['imageUrl'] as String?,
      roles: (data['roles'] is List) ? List.from(data['roles']) : const [],
      leadershipMinistries: (data['leadershipMinistries'] is List)
          ? List.from(data['leadershipMinistries'])
          : const [],
      ministries: (data['ministries'] is List) ? List.from(data['ministries']) : const [],
      isPastor: data['isPastor'] as bool?,
    );
  }

  static String _composeName(Map<String, dynamic> d) {
    final f = (d['firstName'] ?? '').toString().trim();
    final l = (d['lastName'] ?? '').toString().trim();
    final both = (f + ' ' + l).trim();
    return both.isEmpty ? 'Member' : both;
  }

  String get initials {
    final n = (fullName ?? _composeName({
      'firstName': firstName ?? '',
      'lastName': lastName ?? '',
    })).trim();
    if (n.isEmpty) return '?';
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0,1) + parts.last.substring(0,1)).toUpperCase();
  }

  bool hasRole(String role) {
    final r = role.toLowerCase();
    return roles.map((e) => e.toString().toLowerCase()).contains(r);
  }

  bool isLeaderOf(String ministryName) {
    final m = ministryName.toLowerCase();
    final inLeaderMins = leadershipMinistries.map((e) => e.toString().toLowerCase()).contains(m);
    final hasLeaderRole = hasRole('leader');
    final inThisMinistry = ministries.map((e) => e.toString().toLowerCase()).contains(m);
    return inLeaderMins || (hasLeaderRole && inThisMinistry);
  }
}

class _Avatar extends StatelessWidget {
  final String initials;
  final String? photoUrl;
  const _Avatar({required this.initials, this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final radius = 22.0;
    if (photoUrl != null && photoUrl!.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(photoUrl!));
    }
    return CircleAvatar(radius: radius, child: Text(initials));
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String message;
  const _EmptyState({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_outlined, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String title;
  final String message;
  const _ErrorState({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
