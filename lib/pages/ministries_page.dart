// lib/pages/ministries_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart'; // ✅ for optional callable delete
import 'ministries_details_page.dart'; // adjust path as needed

class MinistriesPage extends StatefulWidget {
  const MinistriesPage({super.key});

  @override
  State<MinistriesPage> createState() => _MinistriesPageState();
}

class _MinistriesPageState extends State<MinistriesPage>
    with TickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2'); // ✅

  bool _loading = true;

  bool _isLeader = false;
  bool _isAdmin = false;
  bool _isPastor = false;

  String? _uid;
  String? _memberId;

  final Set<String> _memberMinistries = {};
  final Set<String> _leaderMinistries = {};

  final _searchCtrl = TextEditingController();
  String _query = '';

  // Locally dismissed request ids for tap-to-disintegrate effect
  final Set<String> _dismissedReqIds = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _searchCtrl.addListener(() {
      final v = _searchCtrl.text.trim();
      if (v != _query) setState(() => _query = v);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _uid = null;
        _memberId = null;
        _isLeader = false;
        _isAdmin = false;
        _isPastor = false;
        _memberMinistries.clear();
        _leaderMinistries.clear();
        _loading = false;
      });
      return;
    }

    _uid = user.uid;

    try {
      final u = await _db.collection('users').doc(user.uid).get();
      final data = u.data() ?? {};

      // ---- Single-role model (primary) ----
      final role = (data['role'] ?? '').toString().toLowerCase().trim();

      // ---- Legacy fallbacks tolerated by rules ----
      final legacyRoles = (data['roles'] is List)
          ? List<String>.from(
          (data['roles'] as List).map((e) => e.toString().toLowerCase()))
          : const <String>[];

      _isAdmin =
          role == 'admin' || data['isAdmin'] == true || legacyRoles.contains('admin');
      _isPastor =
          role == 'pastor' || data['isPastor'] == true || legacyRoles.contains('pastor');

      final lmUser = (data['leadershipMinistries'] is List)
          ? List<String>.from(
          (data['leadershipMinistries'] as List).map((e) => e.toString()))
          : const <String>[];

      // Treat admin/pastor as leaders for UI affordances
      _isLeader = _isAdmin ||
          _isPastor ||
          role == 'leader' ||
          data['isLeader'] == true ||
          legacyRoles.contains('leader') ||
          lmUser.isNotEmpty;

      final mid = (data['memberId'] ?? '').toString();
      Set<String> memberMins = {};
      final Set<String> leaderMins = {
        ...lmUser.map((e) => e.trim()).where((e) => e.isNotEmpty)
      };

      if (mid.isNotEmpty) {
        final m = await _db.collection('members').doc(mid).get();
        final md = m.data() ?? {};
        if (md['ministries'] is List) {
          memberMins = {
            ...List.from(md['ministries'])
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
          };
        }
        if (md['leadershipMinistries'] is List) {
          leaderMins.addAll(
            List.from(md['leadershipMinistries'])
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty),
          );
        }
        if (md['isPastor'] == true) _isPastor = true;
      }

      setState(() {
        _memberId = mid.isNotEmpty ? mid : null;
        _memberMinistries
          ..clear()
          ..addAll(memberMins);
        _leaderMinistries
          ..clear()
          ..addAll(leaderMins);
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _memberId = null;
        _memberMinistries.clear();
        _leaderMinistries.clear();
        _loading = false;
      });
    }
  }

  bool _canAccessByName(String name) {
    if (_isAdmin || _isPastor) return true; // full access
    return _leaderMinistries.contains(name) || _memberMinistries.contains(name);
  }

  // ======== New Ministry Request ========
  Future<void> _openNewMinistryDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request New Ministry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Ministry Name', hintText: 'e.g. Worship Team'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descCtrl,
              decoration:
              const InputDecoration(labelText: 'Description (optional)'),
              maxLines: 3,
            ),
            const SizedBox(height: 10),
            const Text(
              'Your request will be reviewed by a Pastor. The ministry will be active only after approval.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit')),
        ],
      ),
    );

    if (ok == true) {
      final name = nameCtrl.text.trim();
      final desc = descCtrl.text.trim();
      await _submitNewMinistryRequest(name, desc);
    }
  }

  Future<void> _submitNewMinistryRequest(String name, String desc) async {
    if (!_isLeader) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only leaders can create new ministries.')),
      );
      return;
    }

    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ministry name is required.')),
      );
      return;
    }

    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;

      final u = await _db.collection('users').doc(uid).get();
      final data = u.data() ?? {};
      final email = (data['email'] ?? '').toString();
      final mid = (data['memberId'] ?? '').toString();
      String? fullName;

      if (mid.isNotEmpty) {
        final m = await _db.collection('members').doc(mid).get();
        final md = m.data() ?? {};
        fullName = (md['fullName'] ?? '').toString().trim();
      }

      await _db.collection('ministry_creation_requests').add({
        'name': name,
        'description': desc,
        'requestedByUid': uid,
        'requesterEmail': email,
        'requesterFullName': fullName,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request submitted for "$name". Pastor notified.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  // ======== Join Request ========
  Future<void> _showJoinPrompt(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join "$name"?'),
        content: const Text(
          'You are not a member of this ministry. Would you like to send a join request?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok == true) await _sendJoinRequest(name);
  }

  Future<void> _sendJoinRequest(String name) async {
    if (_uid == null || _memberId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in first to join a ministry.')),
      );
      return;
    }

    await _db.collection('join_requests').add({
      'memberId': _memberId,            // must equal requesterMemberId() for rules
      'ministryId': name,               // ministry NAME per your rules
      'requestedByUid': _uid,
      'status': 'pending',
      'requestedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Join request sent for "$name".')));
  }

  // ======== Delete Ministry (Pastor/Admin only) ========
  Future<void> _confirmDeleteMinistry({
    required String ministryId,
    required String ministryName,
  }) async {
    if (!(_isPastor || _isAdmin)) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete ministry'),
        content: Text(
          'Are you sure you want to delete "$ministryName"?\n\n'
              'This will remove the ministry record. '
              'If you have a Cloud Function to clean up memberships/feeds, it will run. '
              'This action cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      // Prefer callable (server-side audit & cascade), fallback to direct delete.
      try {
        final callable = _functions.httpsCallable('adminDeleteMinistry');
        await callable.call({
          'ministryId': ministryId,
          'ministryName': ministryName,
        });
      } on Exception {
        // Fallback if function not deployed or blocked by region/permissions.
        await _db.collection('ministries').doc(ministryId).delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$ministryName".')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  // ======== Streams ========
  Stream<List<Map<String, dynamic>>> _ministriesStream() => _db
      .collection('ministries')
      .orderBy('name')
      .snapshots()
      .map((qs) => qs.docs
      .map((d) => {
    'id': d.id,
    'name': (d.data()['name'] ?? '').toString(),
  })
      .toList());

  // Pending-only (auto-vanish when approved/rejected); keep ids for local dismiss.
  Stream<List<Map<String, dynamic>>> _myPendingCreationRequestsStream() {
    if (_uid == null) return const Stream.empty();
    return _db
        .collection('ministry_creation_requests')
        .where('requestedByUid', isEqualTo: _uid)
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs
        .map((d) => {
      'id': d.id,
      'name': d['name'],
      'status': d['status'],
    })
        .toList());
  }

  // All requests for the second tab (history view)
  Stream<List<Map<String, dynamic>>> _myCreationRequestsStream() {
    if (_uid == null) return const Stream.empty();
    return _db
        .collection('ministry_creation_requests')
        .where('requestedByUid', isEqualTo: _uid)
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs
        .map((d) => {
      'id': d.id,
      'name': d['name'],
      'status': d['status'],
    })
        .toList());
  }

  // ======== UI helpers ========
  Color _statusColor(String s) {
    switch (s) {
      case 'approved':
        return Colors.green;
      case 'declined':
      case 'rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Widget _disintegrateTile({
    required String id,
    required Widget child,
  }) {
    final dismissed = _dismissedReqIds.contains(id);

    return AnimatedOpacity(
      key: ValueKey('req_$id'),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      opacity: dismissed ? 0 : 1,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: dismissed ? const SizedBox.shrink() : child,
      ),
    );
  }

  Widget _ministryTile(Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString().trim();
    final id = (m['id'] ?? '').toString();
    final canAccess = _canAccessByName(name);
    final signedIn = _uid != null;
    final canDelete = _isPastor || _isAdmin;

    // Decide trailing widget:
    Widget? trailing;
    if (!canAccess && signedIn && !_isAdmin && !_isPastor) {
      trailing = TextButton.icon(
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Join'),
        onPressed: () => _showJoinPrompt(name),
      );
    } else if (canDelete) {
      trailing = PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') {
            _confirmDeleteMinistry(ministryId: id, ministryName: name);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete, size: 18),
                SizedBox(width: 8),
                Text('Delete'),
              ],
            ),
          ),
        ],
        tooltip: 'More',
      );
    }

    return Card(
      child: ListTile(
        leading: Icon(canAccess ? Icons.groups : Icons.lock_outline),
        title: Text(name),
        trailing: trailing,
        onTap: () {
          if (canAccess) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    MinistryDetailsPage(ministryId: id, ministryName: name),
              ),
            );
          } else if (signedIn) {
            _showJoinPrompt(name);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sign in to join a ministry.')),
            );
          }
        },
      ),
    );
  }

  Widget _sectionHeader(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return DefaultTabController(
      length: _isLeader ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ministries'),
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Ministries'),
              if (_isLeader) const Tab(text: 'My Requests'),
            ],
          ),
          actions: [
            SizedBox(
              width: 220,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search ministries…',
                    border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    suffixIcon: _query.isEmpty
                        ? const Icon(Icons.search)
                        : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchCtrl.clear(),
                    ),
                  ),
                ),
              ),
            ),
            if (_isLeader)
              IconButton(
                tooltip: 'Request New Ministry',
                icon: const Icon(Icons.add_box),
                onPressed: _openNewMinistryDialog,
              ),
          ],
        ),
        floatingActionButton: _isLeader
            ? FloatingActionButton(
          onPressed: _openNewMinistryDialog,
          tooltip: 'Request New Ministry',
          child: const Icon(Icons.add),
        )
            : null,
        body: TabBarView(
          children: [
            // ---- TAB 1: Ministries ----
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _ministriesStream(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // Filter by search query (case-insensitive)
                final all = snap.data!
                    .where((m) => _query.isEmpty
                    ? true
                    : m['name']
                    .toString()
                    .toLowerCase()
                    .contains(_query.toLowerCase()))
                    .toList();

                final fullAccess = _isAdmin || _isPastor;

                final mySet = fullAccess
                    ? all.map((m) => m['name'].toString()).toSet()
                    : {..._memberMinistries, ..._leaderMinistries};

                final myList =
                all.where((m) => mySet.contains(m['name'])).toList();
                final otherList =
                all.where((m) => !mySet.contains(m['name'])).toList();

                return ListView(
                  children: [
                    // 🔸 Pending Requests Section (leaders; pending-only; tap to disintegrate)
                    if (_isLeader)
                      StreamBuilder<List<Map<String, dynamic>>>(
                        stream: _myPendingCreationRequestsStream(),
                        builder: (context, reqSnap) {
                          if (!reqSnap.hasData || reqSnap.data!.isEmpty) {
                            return const SizedBox.shrink();
                          }

                          // Filter out locally dismissed ones (post-tap disintegration)
                          final reqs = reqSnap.data!
                              .where((r) =>
                          !_dismissedReqIds.contains(r['id'] as String))
                              .toList();

                          if (reqs.isEmpty) return const SizedBox.shrink();

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _sectionHeader('Pending Ministry Requests'),
                              ...reqs.map((r) {
                                final id = r['id'] as String;
                                final name = r['name'] as String? ?? '';

                                return _disintegrateTile(
                                  id: id,
                                  child: Card(
                                    child: ListTile(
                                      title: Text(name),
                                      subtitle:
                                      const Text('Awaiting pastoral approval'),
                                      trailing: Chip(
                                        label: const Text('PENDING'),
                                        backgroundColor:
                                        Colors.orange.withOpacity(0.15),
                                        labelStyle: const TextStyle(
                                            color: Colors.orange),
                                      ),
                                      // 👇 Tap to disintegrate locally (pure UX; no write)
                                      onTap: () {
                                        setState(() => _dismissedReqIds.add(id));
                                      },
                                    ),
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      ),

                    _sectionHeader('My Ministries'),
                    if (myList.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('None'),
                      )
                    else
                      ...myList.map(_ministryTile),

                    if (!(_isAdmin || _isPastor)) ...[
                      _sectionHeader('Other Ministries'),
                      if (otherList.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('None'),
                        )
                      else
                        ...otherList.map(_ministryTile),
                    ],
                  ],
                );
              },
            ),

            // ---- TAB 2: Creation Requests (leaders only; full history) ----
            if (_isLeader)
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _myCreationRequestsStream(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final reqs = snap.data!;
                  if (reqs.isEmpty) {
                    return const Center(child: Text('You have no requests.'));
                  }
                  return ListView(
                    padding: const EdgeInsets.all(12),
                    children: reqs.map((r) {
                      final status = (r['status'] ?? '').toString();
                      return Card(
                        child: ListTile(
                          title: Text((r['name'] ?? '').toString()),
                          trailing: Chip(
                            label: Text(status.toUpperCase()),
                            backgroundColor:
                            _statusColor(status).withOpacity(0.15),
                            labelStyle:
                            TextStyle(color: _statusColor(status)),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
