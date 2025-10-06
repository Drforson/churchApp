import 'dart:async';
import 'package:church_management_app/models/join_request_model.dart';
import 'package:church_management_app/models/ministry_model.dart';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

  Set<String> pendingJoinRequests = {};
  Set<String> myMinistryNames = {};
  String _searchQuery = '';

  StreamSubscription<QuerySnapshot>? _pendingWatcherSub;

  bool _callableChecked = false;
  bool _callableAvailable = false;

  bool get isAdmin => roles.contains('admin');
  bool get isLeaderRole => roles.contains('leader');

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      currentUserId = user.uid;
      currentUserEmail = user.email;
      _fetchUserData();
    }
    _probeCallableAvailability();
  }

  @override
  void dispose() {
    _pendingWatcherSub?.cancel();
    super.dispose();
  }

  Future<void> _probeCallableAvailability() async {
    try {
      FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('requestCreateMinistry');
      setState(() {
        _callableChecked = true;
        _callableAvailable = true;
      });
    } catch (_) {
      setState(() {
        _callableChecked = true;
        _callableAvailable = false;
      });
    }
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
      final memSnap = await db.collection('members').doc(linkedMemberId).get();
      if (memSnap.exists) {
        currentMins = (List<String>.from(
            (memSnap.data() ?? {})['ministries'] ?? const <String>[]))
            .toSet();
      }

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

    _bindPendingRequestsWatcher();
  }

  void _bindPendingRequestsWatcher() {
    _pendingWatcherSub?.cancel();
    if (memberId == null || memberId!.isEmpty) return;

    final q = FirebaseFirestore.instance
        .collection('join_requests')
        .where('memberId', isEqualTo: memberId);

    _pendingWatcherSub = q.snapshots().listen((snap) {
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
          pendingJoinRequests = next;
        });
      }
    }, onError: (e) {
      debugPrint('pending watcher error: $e');
    });
  }

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
        const SnackBar(
            content:
            Text('Link your profile to a member record before joining.')),
      );
      return;
    }

    if (myMinistryNames.contains(ministryName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('You are already a member of this ministry.')),
      );
      return;
    }

    if (pendingJoinRequests.contains(ministryName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You already have a pending request.')),
      );
      return;
    }

    try {
      final db = FirebaseFirestore.instance;

      final dup = await db
          .collection('join_requests')
          .where('memberId', isEqualTo: memberId)
          .where('ministryId', isEqualTo: ministryName)
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
        'ministryId': ministryName,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'requestedByUid': currentUserId,
        'requestedByEmail': currentUserEmail,
      });

      setState(() => pendingJoinRequests.add(ministryName));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join request sent!')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Failed to send join request: ${e.message ?? e.code}')),
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

      setState(() => pendingJoinRequests.remove(ministryName));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join request cancelled')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
            Text('Failed to cancel request: ${e.message ?? e.code}')),
      );
    }
  }

  // ======== LEADER: Request new ministry ========

  void _openCreateMinistryDialog() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        bool submitting = false;
        return StatefulBuilder(
          builder: (context, setS) => AlertDialog(
            title: const Text('Request New Ministry'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Ministry name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  decoration:
                  const InputDecoration(labelText: 'Description (optional)'),
                ),
                const SizedBox(height: 8),
                if (_callableChecked && !_callableAvailable)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Backend callable not detected; will create a pending request document.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: submitting
                    ? null
                    : () async {
                  final name = nameCtrl.text.trim();
                  final desc = descCtrl.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Please enter a name.')),
                    );
                    return;
                  }
                  setS(() => submitting = true);
                  try {
                    await _submitCreateMinistryRequest(
                      name: name,
                      description: desc,
                    );
                    if (mounted) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Request sent to pastor for approval.',
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    setS(() => submitting = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed: $e')),
                    );
                  }
                },
                child: const Text('Send Request'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitCreateMinistryRequest({
    required String name,
    required String description,
  }) async {
    final db = FirebaseFirestore.instance;

    // Try callable first
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('requestCreateMinistry');
      await fn.call({
        'name': name,
        'description': description,
        'requestedByUid': currentUserId,
        'requestedByMemberId': memberId,
      });

      // NEW: Also create a best-effort pastor notification even if the callable already does it
      // (harmless duplicate in worst case; add a simple dedupe key).
      await db.collection('notifications').add({
        'type': 'ministry_request',
        'title': 'New ministry creation request',
        'body': '$name submitted for approval',
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
        'toRole': 'pastor',
        'fromUid': currentUserId,
        'dedupeKey': 'req:$name:${currentUserId ?? ''}', // simple dedupe hint
      });
      return;
    } catch (e) {
      debugPrint('requestCreateMinistry callable failed; fallback. $e');
      setState(() => _callableAvailable = false);
    }

    // Fallback to Firestore doc
    final reqRef = db.collection('ministry_creation_requests').doc();
    await reqRef.set({
      'id': reqRef.id,
      'name': name,
      'description': description,
      'status': 'pending', // pending|approved|declined
      'requestedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'requestedByUid': currentUserId,
      'requestedByMemberId': memberId,
      'requesterEmail': currentUserEmail,
    });

    // Ensure a notification to pastors exists in fallback too
    await db.collection('notifications').add({
      'type': 'ministry_request',
      'title': 'New ministry creation request',
      'body': '$name submitted for approval',
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
      'toRole': 'pastor',
      'fromUid': currentUserId,
      'requestId': reqRef.id,
    });
  }

  // NEW: Allow requester/admin to cancel a pending ministry-creation request
  Future<void> _cancelCreateMinistryRequest(String requestId) async {
    final db = FirebaseFirestore.instance;
    try {
      final doc = await db.collection('ministry_creation_requests').doc(requestId).get();
      if (!doc.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This request no longer exists.')),
        );
        return;
      }
      final data = doc.data() as Map<String, dynamic>;
      if ((data['status'] ?? 'pending') != 'pending') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only pending requests can be cancelled.')),
        );
        return;
      }
      final ownerUid = (data['requestedByUid'] ?? '').toString();
      if (!(isAdmin || (currentUserId != null && ownerUid == currentUserId))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You cannot cancel this request.')),
        );
        return;
      }

      await db.collection('ministry_creation_requests').doc(requestId).delete();

      // Optional: notify pastors that the request was cancelled
      await db.collection('notifications').add({
        'type': 'ministry_request_cancelled',
        'title': 'Ministry request cancelled',
        'body': 'A pending ministry creation request was cancelled by its requester.',
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
        'toRole': 'pastor',
        'fromUid': currentUserId,
        'requestId': requestId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cancel: $e')),
      );
    }
  }

  // ======= RENDERING =======

  Widget _buildMinistryLists(
      List<MinistryModel> myMinistries,
      List<MinistryModel> otherMinistries, {
        List<_PendingMinistryCardData> pendingGhosts = const [],
      }) {
    final existingNames = {
      ...myMinistries.map((m) => m.name),
      ...otherMinistries.map((m) => m.name),
    };

    final ghostCards =
    pendingGhosts.where((g) => !existingNames.contains(g.name)).toList();

    return ListView(
      children: [
        if (myMinistries.isNotEmpty) ...[
          _sectionHeader('My Ministries', myMinistries.length, Colors.blue),
          ...myMinistries.map((m) => _buildMinistryCard(m, true)),
        ],
        _sectionHeader(
          'Other Ministries',
          otherMinistries.length + ghostCards.length,
          Colors.green,
        ),
        ...otherMinistries.map((m) => _buildMinistryCard(m, false)),
        ...ghostCards.map(_buildPendingGhostCard),
      ],
    );
  }

  Widget _sectionHeader(String title, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style:
              const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          CircleAvatar(
              backgroundColor: color,
              child: Text('$count',
                  style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  Widget _buildMinistryCard(MinistryModel ministry, bool isMember) {
    final isLeader = _isLeaderOfMinistry(ministry);
    final hasPendingRequest = pendingJoinRequests.contains(ministry.name);
    final alreadyMember = myMinistryNames.contains(ministry.name);

    final approved = ministry.approved;
    final bool hasAccess = (isMember || isAdmin) && approved;

    final canJoin = !isAdmin &&
        !alreadyMember &&
        !hasPendingRequest &&
        memberId != null &&
        approved;

    return FutureBuilder<int>(
      future: _getMemberCount(ministry.name),
      builder: (context, snapshot) {
        final memberCount = snapshot.data ?? 0;

        return Opacity(
          opacity: hasAccess ? 1.0 : 0.6,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 5,
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
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
                              color:
                              hasAccess ? Colors.black : Colors.grey[700],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!approved)
                          const Icon(Icons.lock_outline,
                              size: 20, color: Colors.orange)
                        else if (!hasAccess)
                          const Icon(Icons.lock_outline,
                              size: 20, color: Colors.grey)
                        else if (isAdmin && !isMember)
                            const Icon(Icons.lock_open,
                                size: 20, color: Colors.green),
                      ],
                    ),
                  ),
                  if (isLeader)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
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
                  approved
                      ? '${ministry.description}\nMembers: $memberCount'
                      : 'Pending pastor approval\n${ministry.description.isNotEmpty ? ministry.description : ''}',
                  style: TextStyle(
                      height: 1.5,
                      color: hasAccess ? Colors.black54 : Colors.grey),
                ),
              ),
              trailing: !approved
                  ? const Text('Pending',
                  style: TextStyle(
                      color: Colors.orange, fontWeight: FontWeight.bold))
                  : isAdmin
                  ? null
                  : alreadyMember
                  ? const Text('Member',
                  style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold))
                  : hasPendingRequest
                  ? TextButton(
                onPressed: () =>
                    _cancelJoinRequest(ministry.name),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.red)),
              )
                  : ElevatedButton(
                onPressed: canJoin
                    ? () => _sendJoinRequest(ministry.name)
                    : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor:
                    canJoin ? null : Colors.grey),
                child: const Text('Join'),
              ),
              isThreeLine: true,
              onTap: () {
                if (approved && hasAccess) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MinistryDetailsPage(
                        ministryId: ministry.id,
                        ministryName: ministry.name,
                      ),
                    ),
                  );
                } else if (!approved) {
                  showDialog(
                    context: context,
                    builder: (context) => const AlertDialog(
                      title: Text('Not yet available'),
                      content:
                      Text('This ministry is awaiting pastor approval.'),
                    ),
                  );
                } else {
                  showDialog(
                    context: context,
                    builder: (context) => const AlertDialog(
                      title: Text('Access Denied'),
                      content: Text(
                          'You must be a member or admin to view details.'),
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

  // UPDATED: pending ghost card shows "Cancel" for owner/admin
  Widget _buildPendingGhostCard(_PendingMinistryCardData g) {
    final iOwnThis = currentUserId != null && g.requestedByUid == currentUserId;

    return Opacity(
      opacity: 0.85,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          title: Row(
            children: [
              const Expanded(
                child: Text(
                  'Pending ministry (awaiting approval)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Icon(Icons.lock_outline, size: 20, color: Colors.orange),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6.0),
            child: Text([
              g.name,
              if (g.description != null && g.description!.trim().isNotEmpty)
                g.description!,
              if (iOwnThis) 'Requested by: You'
              else if ((g.requestedByUid ?? '').isNotEmpty)
                'Requested by: ${g.requestedByUid}'
            ].join('\n')),
          ),
          trailing: (iOwnThis || isAdmin)
              ? TextButton(
            onPressed: () => _cancelCreateMinistryRequest(g.id),
            child: const Text('Cancel', style: TextStyle(color: Colors.red)),
          )
              : const Text('Pending',
              style: TextStyle(
                  color: Colors.orange, fontWeight: FontWeight.bold)),
          onTap: () {
            showDialog(
              context: context,
              builder: (context) => const AlertDialog(
                title: Text('Not yet available'),
                content: Text(
                    'This ministry will be accessible after pastor approval.'),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMyJoinRequestsTab() {
    if (memberId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
              'Link your profile to a member record to view your join requests.'),
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

        final requests =
        docs.map((d) => JoinRequestModel.fromDocument(d)).toList();

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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 2,
              child: ListTile(
                contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                title: Text(
                  r.ministryId.isEmpty ? 'Unknown ministry' : r.ministryId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                    'Requested: $whenStr\nStatus: ${r.status[0].toUpperCase()}${r.status.substring(1)}'),
                isThreeLine: true,
                trailing: isPending
                    ? TextButton(
                  onPressed: () => _cancelJoinRequest(r.ministryId),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.red)),
                )
                    : const SizedBox.shrink(),
              ),
            );
          },
        );
      },
    );
  }

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
            if (isLeaderRole)
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Request new ministry',
                onPressed: _openCreateMinistryDialog,
              ),
          ],
        ),
        body: TabBarView(
          children: [
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
                    stream: FirebaseFirestore.instance
                        .collection('ministries')
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final approvedMinistries = snapshot.data!.docs
                          .map((doc) {
                        final data = doc.data() as Map<String, dynamic>;
                        final approved =
                            (data['approved'] as bool?) ?? true;
                        return MinistryModel(
                          id: doc.id,
                          name: data['name'] ?? 'Unnamed Ministry',
                          description: data['description'] ?? '',
                          leaderIds:
                          List<String>.from(data['leaderIds'] ?? []),
                          createdBy: data['createdBy'] ?? '',
                          approved: approved,
                        );
                      })
                          .where((m) =>
                          m.name.toLowerCase().contains(_searchQuery))
                          .toList();

                      Widget buildApproved(
                          List<_PendingMinistryCardData> pendingGhosts) {
                        if (isAdmin || memberId == null) {
                          final myMins = <MinistryModel>[];
                          final others = approvedMinistries;
                          return _buildMinistryLists(myMins, others,
                              pendingGhosts: pendingGhosts);
                        }

                        return StreamBuilder<DocumentSnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('members')
                              .doc(memberId)
                              .snapshots(),
                          builder: (context, memberSnapshot) {
                            if (!memberSnapshot.hasData) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }

                            final memberData = memberSnapshot.data!
                                .data() as Map<String, dynamic>? ??
                                {};
                            final userMinistries =
                            List<String>.from(memberData['ministries'] ?? []);
                            myMinistryNames = userMinistries.toSet();

                            final myMins = approvedMinistries
                                .where((m) => userMinistries.contains(m.name))
                                .toList();
                            final others = approvedMinistries
                                .where((m) => !userMinistries.contains(m.name))
                                .toList();

                            return _buildMinistryLists(myMins, others,
                                pendingGhosts: pendingGhosts);
                          },
                        );
                      }

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('ministry_creation_requests')
                            .where('status', isEqualTo: 'pending')
                            .snapshots(),
                        builder: (context, reqSnap) {
                          final pendingGhosts = <_PendingMinistryCardData>[];
                          if (reqSnap.hasData) {
                            for (final d in reqSnap.data!.docs) {
                              final data =
                              d.data() as Map<String, dynamic>;
                              final n = (data['name'] ?? '').toString();
                              if (n.toLowerCase().contains(_searchQuery)) {
                                pendingGhosts.add(
                                  _PendingMinistryCardData(
                                    id: d.id,
                                    name: n,
                                    description:
                                    (data['description'] ?? '').toString(),
                                    requestedByUid:
                                    (data['requestedByUid'] ?? '').toString(),
                                  ),
                                );
                              }
                            }
                          }
                          return buildApproved(pendingGhosts);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            _buildMyJoinRequestsTab(),
          ],
        ),
      ),
    );
  }
}

class _PendingMinistryCardData {
  final String id;
  final String name;
  final String? description;
  final String? requestedByUid;
  const _PendingMinistryCardData({
    required this.id,
    required this.name,
    this.description,
    this.requestedByUid,
  });
}
