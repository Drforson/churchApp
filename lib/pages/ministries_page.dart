// lib/pages/ministries_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart'; // ✅ for optional callable delete/cancel
import 'ministries_details_page.dart'; // adjust path as needed

class MinistriesPage extends StatefulWidget {
  const MinistriesPage({super.key});

  @override
  State<MinistriesPage> createState() => _MinistriesPageState();
}

class _MinistriesPageState extends State<MinistriesPage>
    with TickerProviderStateMixin {
  // ====== Services
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2'); // ✅

  // ====== Role / Identity
  bool _loading = true;

  bool _isLeader = false;
  bool _isAdmin = false;
  bool _isPastor = false;

  String? _uid;
  String? _memberId;

  final Set<String> _memberMinistries = {};
  final Set<String> _leaderMinistries = {};

  // ====== Search
  final _searchCtrl = TextEditingController();
  String _query = '';

  // ====== Pending Join Requests
  // We store both ministry doc IDs and names here for robust matching.
  final Set<String> _pendingJoinKeys = {};

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

  // ========== Helpers ==========
  bool _isPendingFor({required String id, required String name}) {
    // match if either the doc id or the plain name is present
    return _pendingJoinKeys.contains(id) || _pendingJoinKeys.contains(name);
  }

  // Load pending join requests for this member; track by BOTH ministryId and ministryName
  Future<void> _refreshPendingJoinRequests() async {
    _pendingJoinKeys.clear();
    try {
      final callable =
          _functions.httpsCallable('memberListPendingJoinRequests');
      final res = await callable.call();
      final data = (res.data is Map)
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};

      final fixedMemberId = (data['memberId'] ?? '').toString().trim();
      if (fixedMemberId.isNotEmpty) {
        _memberId = fixedMemberId;
      }

      final items = (data['items'] is List)
          ? List<Map<String, dynamic>>.from(
              (data['items'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map)),
            )
          : const <Map<String, dynamic>>[];

      for (final item in items) {
        final mn = (item['ministryName'] ?? '').toString().trim();
        final mi = (item['ministryId'] ?? '').toString().trim();
        final md = (item['ministryDocId'] ?? '').toString().trim();
        if (mn.isNotEmpty) _pendingJoinKeys.add(mn);
        if (mi.isNotEmpty) _pendingJoinKeys.add(mi);
        if (md.isNotEmpty) _pendingJoinKeys.add(md);
      }
      if (mounted) setState(() {});
    } on FirebaseFunctionsException catch (e) {
      // Fallback for environments where the callable is not deployed yet.
      if (e.code == 'not-found' && _memberId != null) {
        final q = await _db
            .collection('join_requests')
            .where('memberId', isEqualTo: _memberId)
            .where('status', isEqualTo: 'pending')
            .get();
        for (final d in q.docs) {
          final data = d.data();
          final mn = (data['ministryName'] ?? '').toString().trim();
          final mi = (data['ministryId'] ?? '').toString().trim();
          final md = (data['ministryDocId'] ?? '').toString().trim();
          if (mn.isNotEmpty) _pendingJoinKeys.add(mn);
          if (mi.isNotEmpty) _pendingJoinKeys.add(mi);
          if (md.isNotEmpty) _pendingJoinKeys.add(md);
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // ignore
    }
  }

  Future<void> _bootstrap() async {
    final user = _auth.currentUser;
    if (user == null) {
      _uid = null;
      _memberId = null;
      _isLeader = false;
      _isAdmin = false;
      _isPastor = false;
      _memberMinistries.clear();
      _leaderMinistries.clear();
      await _refreshPendingJoinRequests();
      if (mounted) setState(() => _loading = false);
      return;
    }

    _uid = user.uid;

    try {
      final token = await user.getIdTokenResult(true);
      final claims = token.claims ?? const <String, dynamic>{};
      final u = await _db.collection('users').doc(user.uid).get();
      final data = u.data() ?? {};

      // ---- Single-role model (primary) ----
      final role = (data['role'] ?? '').toString().toLowerCase().trim();

      // ---- Legacy fallbacks tolerated by rules ----
      final legacyRoles = (data['roles'] is List)
          ? List<String>.from(
              (data['roles'] as List).map((e) => e.toString().toLowerCase()))
          : const <String>[];

      _isAdmin = role == 'admin' ||
          data['isAdmin'] == true ||
          data['admin'] == true ||
          legacyRoles.contains('admin') ||
          claims['admin'] == true ||
          claims['isAdmin'] == true;
      _isPastor = role == 'pastor' ||
          data['isPastor'] == true ||
          data['pastor'] == true ||
          legacyRoles.contains('pastor') ||
          claims['pastor'] == true ||
          claims['isPastor'] == true;

      final lmUser = (data['leadershipMinistries'] is List)
          ? List<String>.from(
              (data['leadershipMinistries'] as List).map((e) => e.toString()))
          : const <String>[];

      // Treat admin/pastor as leaders for UI affordances
      _isLeader = _isAdmin ||
          _isPastor ||
          role == 'leader' ||
          data['isLeader'] == true ||
          data['leader'] == true ||
          legacyRoles.contains('leader') ||
          lmUser.isNotEmpty ||
          claims['leader'] == true ||
          claims['isLeader'] == true;

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
        final memberRoles = (md['roles'] is List)
            ? List<String>.from(
                (md['roles'] as List).map((e) => e.toString().toLowerCase()),
              )
            : const <String>[];
        if (md['isPastor'] == true || memberRoles.contains('pastor'))
          _isPastor = true;
        if (memberRoles.contains('admin')) _isAdmin = true;
        if (memberRoles.contains('leader') || leaderMins.isNotEmpty)
          _isLeader = true;
      }

      if (_isAdmin || _isPastor) _isLeader = true;

      _memberId = mid.isNotEmpty ? mid : null;
      _memberMinistries
        ..clear()
        ..addAll(memberMins);
      _leaderMinistries
        ..clear()
        ..addAll(leaderMins);

      // ensure pending join requests state is fresh
      await _refreshPendingJoinRequests();

      if (mounted) setState(() => _loading = false);
    } catch (_) {
      _memberId = null;
      _memberMinistries.clear();
      _leaderMinistries.clear();
      await _refreshPendingJoinRequests();
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _canAccessByName(String name) {
    if (_isAdmin || _isPastor) return true; // full access
    return _leaderMinistries.contains(name) || _memberMinistries.contains(name);
  }

  // ======== New Ministry Request ========
  Future<void> _openNewMinistryDialog() async {
    if (_isPastor || _isAdmin) {
      await _openDirectCreateMinistryDialog();
      return;
    }

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
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Submit')),
        ],
      ),
    );

    if (ok == true) {
      final name = nameCtrl.text.trim();
      final desc = descCtrl.text.trim();
      await _submitNewMinistryRequest(name, desc);
    }
  }

  Future<void> _openDirectCreateMinistryDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final searchCtrl = TextEditingController();
    final selectedLeaderIds = <String>{};
    final membersFuture = _db.collection('members').get();

    String query = '';

    final ok = await showDialog<bool>(
      context: context,
      useSafeArea: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) {
          final mq = MediaQuery.of(dialogContext);
          final contentHeight =
              (((mq.size.height - mq.viewInsets.bottom) * 0.72) - 2)
                  .clamp(278.0, 618.0)
                  .toDouble();

          return AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            title: const Text('Create Ministry'),
            content: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 460,
              height: contentHeight,
              child: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                future: membersFuture,
                builder: (context, snap) {
                  Widget leadersBody;
                  if (snap.connectionState == ConnectionState.waiting) {
                    leadersBody =
                        const Center(child: CircularProgressIndicator());
                  } else {
                    final docs = snap.data?.docs ?? const [];
                    final rows = docs.map((d) {
                      final data = d.data();
                      final first = (data['firstName'] ?? '').toString().trim();
                      final last = (data['lastName'] ?? '').toString().trim();
                      final fullName = (data['fullName'] ?? '$first $last')
                          .toString()
                          .trim();
                      final fallback = fullName.isEmpty
                          ? (data['email'] ?? 'Member').toString()
                          : fullName;
                      return <String, String>{'id': d.id, 'name': fallback};
                    }).where((m) {
                      if (query.isEmpty) return true;
                      return m['name']!.toLowerCase().contains(query);
                    }).toList()
                      ..sort((a, b) => a['name']!.compareTo(b['name']!));

                    leadersBody = Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: rows.isEmpty
                          ? const Center(child: Text('No members found.'))
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, i) {
                                final row = rows[i];
                                final id = row['id']!;
                                final name = row['name']!;
                                final checked = selectedLeaderIds.contains(id);
                                return CheckboxListTile(
                                  dense: true,
                                  value: checked,
                                  title: Text(name),
                                  onChanged: (v) {
                                    setLocalState(() {
                                      if (v == true) {
                                        selectedLeaderIds.add(id);
                                      } else {
                                        selectedLeaderIds.remove(id);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Ministry Name',
                          hintText: 'e.g. Worship Team',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: descCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Description (optional)'),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: searchCtrl,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: 'Search members for leaders',
                        ),
                        onChanged: (v) {
                          setLocalState(() => query = v.trim().toLowerCase());
                        },
                      ),
                      const SizedBox(height: 8),
                      Flexible(child: leadersBody),
                      const SizedBox(height: 8),
                      Text('Selected leaders: ${selectedLeaderIds.length}'),
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (nameCtrl.text.trim().isEmpty) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                          content: Text('Ministry name is required.')),
                    );
                    return;
                  }
                  if (selectedLeaderIds.isEmpty) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                          content: Text('Select at least one leader.')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {
      await _createMinistryDirectly(
        nameCtrl.text.trim(),
        descCtrl.text.trim(),
        selectedLeaderIds.toList(),
      );
    }
  }

  Future<void> _createMinistryDirectly(
    String name,
    String desc,
    List<String> leaderMemberIds,
  ) async {
    if (!(_isPastor || _isAdmin)) return;

    try {
      final callable = _functions.httpsCallable('adminCreateMinistry');
      await callable.call({
        'name': name,
        'description': desc,
        'leaderMemberIds': leaderMemberIds,
      });
      await _bootstrap();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created "$name" successfully.')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      if (e.code == 'not-found') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'adminCreateMinistry is not deployed yet in europe-west2. Deploy Functions and try again.',
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Create failed: ${e.message ?? e.code}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Create failed: $e')),
      );
    }
  }

  Future<void> _submitNewMinistryRequest(String name, String desc) async {
    if (!_isLeader) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Only leaders can create new ministries.')),
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
        if (mid.isNotEmpty) 'requesterMemberId': mid,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Request submitted for "$name". Pastor notified.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  // ======== Join Request ========
  Future<void> _showJoinPrompt(
      {required String id, required String name}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join "$name"?'),
        content: const Text(
          'You are not a member of this ministry. Would you like to send a join request?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok == true) await _sendJoinRequest(id: id, name: name);
  }

  Future<void> _sendJoinRequest(
      {required String id, required String name}) async {
    if (_uid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in first to join a ministry.')),
      );
      return;
    }

    try {
      final callable = _functions.httpsCallable('memberCreateJoinRequest');
      final res = await callable.call({
        'ministryId': id,
        'ministryName': name,
      });

      final data = (res.data is Map)
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      final ministryName = (data['ministryName'] ?? name).toString();
      final ministryId = (data['ministryId'] ?? id).toString();
      final duplicate = data['duplicate'] == true;

      _pendingJoinKeys.add(ministryName);
      _pendingJoinKeys.add(ministryId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            duplicate
                ? 'You already have a pending request for "$ministryName".'
                : 'Join request sent for "$ministryName".',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      if (e.code == 'not-found') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'memberCreateJoinRequest is not deployed yet in europe-west2.',
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Join request failed: ${e.message ?? e.code}')),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Join request failed: $e')),
      );
      return;
    }

    await _refreshPendingJoinRequests();
  }

  // ======== Cancel Join Request ========
  Future<void> _confirmCancelJoin(
      {required String id, required String name}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel join request?'),
        content: Text('Withdraw your pending request for "$name"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, cancel')),
        ],
      ),
    );

    if (ok == true) {
      await _cancelPendingJoin(id: id, name: name);
    }
  }

  Future<void> _cancelPendingJoin(
      {required String id, required String name}) async {
    if (_uid == null) return;

    try {
      // Use callable first to avoid client-side rules failures on join_requests queries.
      final func = _functions.httpsCallable('memberCancelJoinRequest');
      await func.call({
        'memberId': _memberId,
        'ministryId': id,
        'ministryName': name,
      });

      // Update local UI state
      _pendingJoinKeys.remove(name);
      _pendingJoinKeys.remove(id);
      await _refreshPendingJoinRequests();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cancelled request for "$name".')),
        );
      }
    } on FirebaseFunctionsException catch (e2) {
      // Temporary fallback only when callable not deployed in this environment.
      if (e2.code == 'not-found' && _memberId != null) {
        try {
          var q = await _db
              .collection('join_requests')
              .where('memberId', isEqualTo: _memberId)
              .where('status', isEqualTo: 'pending')
              .where('ministryId', isEqualTo: id)
              .limit(1)
              .get();

          if (q.docs.isEmpty) {
            q = await _db
                .collection('join_requests')
                .where('memberId', isEqualTo: _memberId)
                .where('status', isEqualTo: 'pending')
                .where('ministryName', isEqualTo: name)
                .limit(1)
                .get();
          }

          if (q.docs.isNotEmpty) {
            await q.docs.first.reference.delete();
            _pendingJoinKeys.remove(name);
            _pendingJoinKeys.remove(id);
            await _refreshPendingJoinRequests();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Cancelled request for "$name".')),
              );
            }
            return;
          }
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel: ${e2.message ?? e2.code}')),
        );
      }
    } catch (e2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel: $e2')),
        );
      }
    }
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
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
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
      final callable = _functions.httpsCallable('adminDeleteMinistry');
      await callable.call({
        'ministryId': ministryId,
        'ministryName': ministryName,
      });

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

  // Pending-only (defensive normalization too)
  Stream<List<Map<String, dynamic>>> _myPendingCreationRequestsStream() {
    if (_uid == null) return const Stream.empty();

    return _db
        .collection('ministry_creation_requests')
        .where('requestedByUid', isEqualTo: _uid)
        .where('status', isEqualTo: 'pending') // server-side filter
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs
            .map((d) {
              final map = d.data();
              final rawStatus = (map['status'] ?? '').toString();
              final status = rawStatus.trim().toLowerCase(); // normalize
              final name = (map['name'] ?? '').toString();
              return {
                'id': d.id,
                'name': name,
                'status': status,
              };
            })
            // client-side defensive filter (ignores stale/odd-cased docs)
            .where((m) => (m['status'] as String) == 'pending')
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
        .map((qs) => qs.docs.map((d) {
              final map = d.data();
              return {
                'id': d.id,
                'name': (map['name'] ?? '').toString(),
                'status': (map['status'] ?? '').toString().trim().toLowerCase(),
              };
            }).toList());
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
    final pending = _isPendingFor(id: id, name: name);

    // Decide trailing widget:
    Widget? trailing;
    if (!canAccess && signedIn && !_isAdmin && !_isPastor) {
      trailing = pending
          ? TextButton.icon(
              icon: const Icon(Icons.cancel),
              label: const Text('Cancel request'),
              onPressed: () => _confirmCancelJoin(id: id, name: name),
            )
          : TextButton.icon(
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Join'),
              onPressed: () => _showJoinPrompt(id: id, name: name),
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
        title: Row(
          children: [
            Expanded(child: Text(name)),
            if (pending)
              const Text(
                'Pending',
                style: TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
          ],
        ),
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
            _showJoinPrompt(id: id, name: name);
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
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
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
                tooltip: (_isPastor || _isAdmin)
                    ? 'Create Ministry'
                    : 'Request New Ministry',
                icon: const Icon(Icons.add_box),
                onPressed: _openNewMinistryDialog,
              ),
          ],
        ),
        floatingActionButton: _isLeader
            ? FloatingActionButton(
                onPressed: _openNewMinistryDialog,
                tooltip: (_isPastor || _isAdmin)
                    ? 'Create Ministry'
                    : 'Request New Ministry',
                child: const Icon(Icons.add),
              )
            : null,
        body: TabBarView(
          children: [
            // ---- TAB 1: Ministries ----
            RefreshIndicator(
              onRefresh: _refreshPendingJoinRequests,
              child: StreamBuilder<List<Map<String, dynamic>>>(
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

                            // Filter out locally dismissed AND ensure status is truly 'pending'
                            final reqs = reqSnap.data!
                                .where((r) =>
                                    !_dismissedReqIds
                                        .contains(r['id'] as String) &&
                                    (r['status'] as String)
                                            .trim()
                                            .toLowerCase() ==
                                        'pending')
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
                                        subtitle: const Text(
                                            'Awaiting pastoral approval'),
                                        trailing: Chip(
                                          label: const Text('PENDING'),
                                          backgroundColor:
                                              Colors.orange.withOpacity(0.15),
                                          labelStyle: const TextStyle(
                                              color: Colors.orange),
                                        ),
                                        // 👇 Tap to disintegrate locally (pure UX; no write)
                                        onTap: () {
                                          setState(
                                              () => _dismissedReqIds.add(id));
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
                            labelStyle: TextStyle(color: _statusColor(status)),
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
