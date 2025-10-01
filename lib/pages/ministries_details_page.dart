// lib/pages/ministry_details_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/firestore_paths.dart';
import 'ministry_feed_page.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;
  final String ministryName;

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

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this); // Overview / Members / Feed
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
            Tab(text: 'Overview'),
            Tab(text: 'Members'),
            Tab(text: 'Feed'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _OverviewTab(ministryId: widget.ministryId),
          _MembersTab(
            ministryName: widget.ministryName,
            ministryId: widget.ministryId,
          ),
          MinistryFeedPage(
            ministryId: widget.ministryId,
            ministryName: widget.ministryName,
          ),
        ],
      ),
    );
  }
}

// ------------------------------ Overview Tab ------------------------------
class _OverviewTab extends StatelessWidget {
  final String ministryId;
  const _OverviewTab({required this.ministryId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance.doc(FP.ministry(ministryId)).get(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data?.data() ?? {};
          final description = (data['description'] ?? '') as String;
          final createdAt = data['createdAt'];
          final created = (createdAt is Timestamp) ? createdAt.toDate() : null;

          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Ministry ID'),
                subtitle: Text(ministryId),
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('About', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(description),
              ],
              if (created != null) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.event_note, size: 18),
                    const SizedBox(width: 6),
                    Text('Created: ${DateFormat.yMMMd().add_jm().format(created.toLocal())}'),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------ Members Tab ------------------------------
class _MembersTab extends StatefulWidget {
  final String ministryName;
  final String? ministryId;

  const _MembersTab({
    super.key,
    required this.ministryName,
    this.ministryId,
  });

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  late Future<List<Map<String, dynamic>>> membersFuture;
  late Future<List<Map<String, dynamic>>> joinRequestsFuture;

  String? currentUserId;
  Map<String, dynamic>? currentUserData;
  final Set<String> _processingRequests = {};
  List<Map<String, dynamic>> allMembers = [];
  List<Map<String, dynamic>> filteredMembers = [];
  final TextEditingController _searchController = TextEditingController();
  String _filterType = 'All'; // All, Leaders, Members

  @override
  void initState() {
    super.initState();
    currentUserId = FirebaseAuth.instance.currentUser?.uid;
    _fetchCurrentUser();
    membersFuture = _fetchMembers();
    joinRequestsFuture = _fetchJoinRequests();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchCurrentUser() async {
    if (currentUserId == null) return;
    try {
      final userDoc =
      await FirebaseFirestore.instance.collection('users').doc(currentUserId).get();
      if (userDoc.exists) {
        final data = userDoc.data() ?? {};
        final roles = (data['roles'] is List) ? List<String>.from(data['roles']) : <String>[];
        final leadershipMinistries = (data['leadershipMinistries'] is List)
            ? List<String>.from(data['leadershipMinistries'])
            : <String>[];
        setState(() {
          currentUserData = {
            'roles': roles,
            'leadershipMinistries': leadershipMinistries,
          };
        });
      }
    } catch (e) {
      debugPrint('Error fetching user: $e');
    }
  }

  bool isAdmin() {
    if (currentUserData == null) return false;
    final roles = List<String>.from(currentUserData!['roles']);
    return roles.contains('admin');
  }

  bool isAdminOrLeaderOfThisMinistry() {
    if (currentUserData == null) return false;
    final roles = List<String>.from(currentUserData!['roles']);
    final leadershipMinistries =
    List<String>.from(currentUserData!['leadershipMinistries']);
    return roles.contains('admin') ||
        (roles.contains('leader') && leadershipMinistries.contains(widget.ministryName));
  }

  // ---------------- Fetch Members ----------------
  Future<List<Map<String, dynamic>>> _fetchMembers() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('members')
        .where('ministries', arrayContains: widget.ministryName)
        .get();

    final members = snapshot.docs.map((doc) {
      final data = doc.data();
      return {
        'id': doc.id,
        'name': ('${data['firstName'] ?? ''} ${data['lastName'] ?? ''}').trim(),
        'email': data['email'] ?? '',
        'ministries': List<String>.from(data['ministries'] ?? []),
        'isLeader': (data['leadershipMinistries'] ?? []).contains(widget.ministryName),
      };
    }).toList();

    allMembers = members;
    filteredMembers = members;
    return members;
  }

  // ---------------- Fetch Join Requests ----------------
  Future<Map<String, dynamic>?> fetchMemberByMemberId(String memberId) async {
    try {
      final memberDoc =
      await FirebaseFirestore.instance.collection('members').doc(memberId).get();
      if (!memberDoc.exists) return null;
      return memberDoc.data();
    } catch (e) {
      debugPrint('❌ Error fetching member by memberId: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchJoinRequests() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('join_requests')
          .where('ministryId', isEqualTo: widget.ministryName)
          .where('status', isEqualTo: 'pending')
          .orderBy('requestedAt', descending: true)
          .get();

      return Future.wait(snapshot.docs.map((doc) async {
        final data = doc.data();
        final memberId = (data['memberId'] ?? '').toString();

        String fullName = 'Unknown Member';
        DateTime reqAt = DateTime.now();

        if (data['requestedAt'] is Timestamp) {
          reqAt = (data['requestedAt'] as Timestamp).toDate();
        }

        if (memberId.isNotEmpty) {
          final memberData = await fetchMemberByMemberId(memberId);
          if (memberData != null) {
            final fn = (memberData['firstName'] ?? '').toString();
            final ln = (memberData['lastName'] ?? '').toString();
            final composed = ('$fn $ln').trim();
            if (composed.isNotEmpty) fullName = composed;
          }
        }

        return {
          'id': doc.id,
          'memberId': memberId,
          'requestedAt': reqAt,
          'fullName': fullName,
        };
      }).toList());
    } catch (e) {
      debugPrint('❌ Error fetching join requests: $e');
      return [];
    }
  }

  // ---------------- Approve / Reject ----------------
  Future<void> _approveJoinRequest(String requestId, String memberId) async {
    setState(() => _processingRequests.add(requestId));
    try {
      final jrRef = FirebaseFirestore.instance.collection('join_requests').doc(requestId);
      final jrSnap = await jrRef.get();
      if (!jrSnap.exists) throw Exception('Join request not found.');

      final memberRef = FirebaseFirestore.instance.collection('members').doc(memberId);
      final memberSnap = await memberRef.get();
      if (!memberSnap.exists) throw Exception('Member not found.');

      await jrRef.update({
        'status': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await memberRef.update({
        'ministries': FieldValue.arrayUnion([widget.ministryName]),
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Request approved')),
      );

      setState(() {
        joinRequestsFuture = _fetchJoinRequests();
        membersFuture = _fetchMembers();
      });
    } catch (e) {
      debugPrint('❌ Error approving join request: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error approving request: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _processingRequests.remove(requestId));
    }
  }

  Future<void> _rejectJoinRequest(String requestId) async {
    setState(() => _processingRequests.add(requestId));
    try {
      await FirebaseFirestore.instance
          .collection('join_requests')
          .doc(requestId)
          .update({
        'status': 'rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Request rejected')),
      );
      setState(() => joinRequestsFuture = _fetchJoinRequests());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error rejecting request: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _processingRequests.remove(requestId));
    }
  }

  // ---------------- UI ----------------
  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      filteredMembers = allMembers.where((member) {
        final name = (member['name'] as String).toLowerCase();
        final email = (member['email'] as String).toLowerCase();
        final matchesSearch = name.contains(query) || email.contains(query);
        if (_filterType == 'Leaders') {
          return matchesSearch && member['isLeader'] == true;
        } else if (_filterType == 'Members') {
          return matchesSearch && member['isLeader'] != true;
        }
        return matchesSearch;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return currentUserData == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
      onRefresh: () async {
        setState(() {
          membersFuture = _fetchMembers();
          joinRequestsFuture = _fetchJoinRequests();
        });
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isAdminOrLeaderOfThisMinistry()) ...[
            const Text('Join Requests',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: joinRequestsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final requests = snapshot.data ?? [];
                if (requests.isEmpty) {
                  return const Text('No pending join requests.');
                }
                return Column(
                  children: requests.map((request) {
                    return Card(
                      child: ListTile(
                        title: Text(request['fullName']),
                        subtitle: Text(
                          'Requested at: ${DateFormat.yMMMd().format(request['requestedAt'])}',
                        ),
                        trailing: _processingRequests.contains(request['id'])
                            ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                            : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check_circle, color: Colors.green),
                              onPressed: () => _approveJoinRequest(
                                request['id'],
                                request['memberId'],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.red),
                              onPressed: () => _rejectJoinRequest(request['id']),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
          const Text('Members',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: membersFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final members = filteredMembers;
              if (members.isEmpty) {
                return const Text('No members found.');
              }
              return Column(
                children: members.map((member) {
                  return Card(
                    child: ListTile(
                      leading: member['isLeader'] == true
                          ? const Icon(Icons.star, color: Colors.amber)
                          : const Icon(Icons.person_outline),
                      title: Text(member['name']),
                      subtitle: Text(member['email']),
                    ),
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
