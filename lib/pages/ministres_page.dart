import 'dart:async';
import 'package:church_management_app/models/join_request_model.dart';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../models/ministry_model.dart';
import 'ministries_details_page.dart';

class MinistresPage extends StatefulWidget {
  const MinistresPage({super.key});

  @override
  State<MinistresPage> createState() => _MinistresPageState();
}

class _MinistresPageState extends State<MinistresPage> {
  String? currentUserId;
  String? memberId;
  String? currentUserEmail;
  List<String> roles = [];
  bool _loading = true;
  Set<String> pendingJoinRequests = {}; // set of ministry NAMES with pending requests
  Set<String> myMinistryNames = {};     // current memberships for this member
  String _searchQuery = '';

  // 🔹 NEW: live watcher for join_requests to keep both tabs in sync
  StreamSubscription<QuerySnapshot>? _pendingWatcherSub;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      currentUserId = user.uid;
      currentUserEmail = user.email;
      _fetchUserData();
    }
  }

  @override
  void dispose() {
    _pendingWatcherSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchUserData() async {
    if (currentUserId == null) return;

    final db = FirebaseFirestore.instance;
    final userDoc = await db.collection('users').doc(currentUserId).get();
    if (!userDoc.exists) {
      setState(() {
        roles = [];
        memberId = null;
        pendingJoinRequests = {};
        myMinistryNames = {};
        _loading = false;
      });
      return;
    }

    final data = userDoc.data()!;
    final fetchedRoles = List<String>.from(data['roles'] ?? []);
    final linkedMemberId = data['memberId'] as String?;

    Set<String> pendingNames = {};
    Set<String> currentMins = {};

    if (linkedMemberId != null && linkedMemberId.isNotEmpty) {
      // current memberships
      final memSnap = await db.collection('members').doc(linkedMemberId).get();
      if (memSnap.exists) {
        currentMins = (List<String>.from(
            (memSnap.data() ?? {})['ministries'] ?? const <String>[]))
            .toSet();
      }

      // pending requests
      final jrSnap = await db
          .collection('join_requests')
          .where('memberId', isEqualTo: linkedMemberId)
          .where('status', isEqualTo: 'pending')
          .get();
      pendingNames = jrSnap.docs
          .map((d) => (d.data()['ministryId'] as String))
          .toSet();
    }

    setState(() {
      roles = fetchedRoles;
      memberId = linkedMemberId;
      myMinistryNames = currentMins;
      pendingJoinRequests = pendingNames;
      _loading = false;
    });

    // 🔹 Bind live watcher AFTER memberId is known
    _bindPendingRequestsWatcher();
  }

  // 🔹 NEW: live watcher to keep pendingJoinRequests up-to-date everywhere
  void _bindPendingRequestsWatcher() {
    _pendingWatcherSub?.cancel();
    if (memberId == null || memberId!.isEmpty) return;

    final q = FirebaseFirestore.instance
        .collection('join_requests')
        .where('memberId', isEqualTo: memberId);

    _pendingWatcherSub = q.snapshots().listen((snap) {
      // Rebuild the set from current snapshot: only PENDING remain
      final next = <String>{};
      for (final d in snap.docs) {
        final data = d.data() as Map<String, dynamic>;
        final status = (data['status'] ?? 'pending').toString();
        if (status == 'pending') {
          next.add((data['ministryId'] ?? '').toString());
        }
      }
      if (mounted) {
        setState(() {
          pendingJoinRequests = next; // ⟵ updates Join buttons instantly
        });
      }
    }, onError: (e) {
      debugPrint('pending watcher error: $e');
    });
  }

  bool get isAdmin => roles.contains('admin');

  bool _isLeaderOfMinistry(MinistryModel ministry) {
    return ministry.leaderIds.contains(currentUserId);
  }

  Future<int> _getMemberCount(String ministryName) async {
    final membersSnapshot = await FirebaseFirestore.instance
        .collection('members')
        .where('ministries', arrayContains: ministryName)
        .get();
    return membersSnapshot.size;
  }

  Future<void> _sendJoinRequest(String ministryName) async {
    if (memberId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link your profile to a member record before joining.')),
      );
      return;
    }

    // Guard: already member?
    if (myMinistryNames.contains(ministryName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are already a member of this ministry.')),
      );
      return;
    }

    // Guard: already pending?
    if (pendingJoinRequests.contains(ministryName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You already have a pending request for this ministry.')),
      );
      return;
    }

    try {
      final db = FirebaseFirestore.instance;

      // Double-check on server
      final dup = await db
          .collection('join_requests')
          .where('memberId', isEqualTo: memberId)
          .where('ministryId', isEqualTo: ministryName) // ⚠️ ministry NAME
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();
      if (dup.docs.isNotEmpty) {
        setState(() => pendingJoinRequests.add(ministryName));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A pending request already exists.')),
        );
        return;
      }

      final ref = db.collection('join_requests').doc();
      await ref.set({
        'id': ref.id,
        'memberId': memberId,
        'ministryId': ministryName,           // ⚠️ NAME used by rules/listeners
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        // helpful extras
        'requestedByUid': currentUserId,
        'requestedByEmail': currentUserEmail,
      });

      // Optimistic UI; watcher will confirm/update as well
      setState(() => pendingJoinRequests.add(ministryName));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join request sent!')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send join request: ${e.message ?? e.code}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send join request: $e')),
      );
    }
  }

  Future<void> _cancelJoinRequest(String ministryName) async {
    if (memberId == null) return;

    try {
      final db = FirebaseFirestore.instance;
      final query = await db
          .collection('join_requests')
          .where('memberId', isEqualTo: memberId)
          .where('ministryId', isEqualTo: ministryName)
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No pending request found to cancel.')),
        );
        return;
      }

      await db.collection('join_requests').doc(query.docs.first.id).delete();

      // Optimistic update; watcher will sync state even if something else changes
      setState(() => pendingJoinRequests.remove(ministryName));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join request cancelled')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cancel request: ${e.message ?? e.code}')),
      );
    }
  }

  Widget _buildMinistryLists(List<MinistryModel> myMinistries, List<MinistryModel> otherMinistries) {
    return ListView(
      children: [
        if (myMinistries.isNotEmpty) ...[
          _sectionHeader('My Ministries', myMinistries.length, Colors.blue),
          ...myMinistries.map((m) => _buildMinistryCard(m, true)),
        ],
        _sectionHeader('Other Ministries', otherMinistries.length, Colors.green),
        ...otherMinistries.map((m) => _buildMinistryCard(m, false)),
      ],
    );
  }

  Widget _sectionHeader(String title, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          CircleAvatar(backgroundColor: color, child: Text('$count', style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  Widget _buildMinistryCard(MinistryModel ministry, bool isMember) {
    final isLeader = _isLeaderOfMinistry(ministry);
    final hasPendingRequest = pendingJoinRequests.contains(ministry.name);
    final alreadyMember = myMinistryNames.contains(ministry.name);
    final bool hasAccess = isMember || isAdmin;

    final canJoin = !isAdmin && !alreadyMember && !hasPendingRequest && memberId != null;

    return FutureBuilder<int>(
      future: _getMemberCount(ministry.name),
      builder: (context, snapshot) {
        final memberCount = snapshot.data ?? 0;

        return Opacity(
          opacity: hasAccess ? 1.0 : 0.6,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 5,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              title: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            ministry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: hasAccess ? Colors.black : Colors.grey[700],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!hasAccess)
                          const Icon(Icons.lock_outline, size: 20, color: Colors.grey)
                        else if (isAdmin && !isMember)
                          const Icon(Icons.lock_open, size: 20, color: Colors.green),
                      ],
                    ),
                  ),
                  if (isLeader)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Leader',
                        style: TextStyle(
                          color: Colors.blue,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  '${ministry.description}\nMembers: $memberCount',
                  style: TextStyle(height: 1.5, color: hasAccess ? Colors.black54 : Colors.grey),
                ),
              ),
              trailing: isAdmin
                  ? null
                  : alreadyMember
                  ? const Text('Member', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))
                  : hasPendingRequest
                  ? TextButton(
                onPressed: () => _cancelJoinRequest(ministry.name),
                child: const Text('Cancel', style: TextStyle(color: Colors.red)),
              )
                  : ElevatedButton(
                onPressed: canJoin ? () => _sendJoinRequest(ministry.name) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: canJoin ? null : Colors.grey,
                ),
                child: const Text('Join'),
              ),
              isThreeLine: true,
              onTap: () {
                if (hasAccess) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MinistryDetailsPage(
                        ministryId: ministry.id,
                        ministryName: ministry.name,
                      ),
                    ),
                  );
                } else {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Access Denied'),
                      content: const Text('You must be a member or admin to view details.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                }
              },
            ),
          ),
        );
      },
    );
  }

  // -------------------- JOIN REQUESTS TAB --------------------

  Widget _buildMyJoinRequestsTab() {
    if (memberId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text('Link your profile to a member record to view your join requests.'),
        ),
      );
    }

    final baseQuery = FirebaseFirestore.instance
        .collection('join_requests')
        .where('memberId', isEqualTo: memberId);

    return StreamBuilder<QuerySnapshot>(
      stream: baseQuery.orderBy('requestedAt', descending: true).snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Text('You have not sent any join requests yet.'),
            ),
          );
        }

        final requests = docs.map((d) => JoinRequestModel.fromDocument(d)).toList();

        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: requests.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, i) {
            final r = requests[i];
            final when = r.requestedAt.toDate();
            final whenStr = DateFormat('EEE, MMM d • h:mm a').format(when);
            final isPending = r.status == 'pending';

            return Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 2,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                title: Text(
                  r.ministryId.isEmpty ? 'Unknown ministry' : r.ministryId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('Requested: $whenStr\nStatus: ${r.status[0].toUpperCase()}${r.status.substring(1)}'),
                isThreeLine: true,
                trailing: isPending
                    ? TextButton(
                  onPressed: () => _cancelJoinRequest(r.ministryId),
                  child: const Text('Cancel', style: TextStyle(color: Colors.red)),
                )
                    : const SizedBox.shrink(),
              ),
            );
          },
        );
      },
    );
  }

  // -------------------- BUILD --------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ministries'),
          bottom: const TabBar(
            isScrollable: false,
            tabs: [
              Tab(icon: Icon(Icons.church), text: 'Ministries'),
              Tab(icon: Icon(Icons.pending_actions), text: 'My Join Requests'),
            ],
          ),
          actions: [
            const NotificationBell(),
            if (isAdmin)
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  // TODO: open create ministry flow
                },
              ),
          ],
        ),
        body: TabBarView(
          children: [
            // TAB 1: Ministries
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search ministries...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value.trim().toLowerCase();
                      });
                    },
                  ),
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('ministries').snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                      final allMinistries = snapshot.data!.docs.map((doc) {
                        final data = doc.data() as Map<String, dynamic>;
                        return MinistryModel(
                          id: doc.id,
                          name: data['name'] ?? 'Unnamed Ministry',
                          description: data['description'] ?? '',
                          leaderIds: List<String>.from(data['leaderIds'] ?? []),
                          createdBy: data['createdBy'] ?? '',
                        );
                      }).where((m) => m.name.toLowerCase().contains(_searchQuery)).toList();

                      // Admin sees all, not segregated into "my"
                      if (isAdmin || memberId == null) {
                        final myMinistries = <MinistryModel>[];
                        final otherMinistries = allMinistries;
                        return _buildMinistryLists(myMinistries, otherMinistries);
                      }

                      // Non-admin: split by membership names (reactive)
                      return StreamBuilder<DocumentSnapshot>(
                        stream: FirebaseFirestore.instance.collection('members').doc(memberId).snapshots(),
                        builder: (context, memberSnapshot) {
                          if (!memberSnapshot.hasData) return const Center(child: CircularProgressIndicator());

                          final memberData = memberSnapshot.data!.data() as Map<String, dynamic>? ?? {};
                          final userMinistries = List<String>.from(memberData['ministries'] ?? []);

                          // Keep local cache updated so Join button state is correct
                          myMinistryNames = userMinistries.toSet();

                          final myMinistries = allMinistries.where((m) => userMinistries.contains(m.name)).toList();
                          final otherMinistries = allMinistries.where((m) => !userMinistries.contains(m.name)).toList();

                          return _buildMinistryLists(myMinistries, otherMinistries);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            // TAB 2: My Join Requests
            _buildMyJoinRequestsTab(),
          ],
        ),
      ),
    );
  }
}
