import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/firestore_paths.dart';

class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key});

  @override
  State<PastorMinistryApprovalsPage> createState() => _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState extends State<PastorMinistryApprovalsPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool _loadingRole = true;
  bool _canModerate = false; // pastor || admin (users doc, claims, or member fallback)
  String? _uid;

  Map<String, dynamic> _debug = {};
  final Map<String, String> _nameCache = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;

  @override
  void initState() {
    super.initState();
    _wireRoleListener();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _userSub = null;
    super.dispose();
  }

  // Mirrors RoleGate: users → (else) members fallback; plus custom claims
  Future<void> _wireRoleListener() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _uid = null;
        _loadingRole = false;
        _canModerate = false;
        _debug = {'reason': 'no-auth-user'};
      });
      return;
    }
    _uid = user.uid;

    _userSub = _db.collection(FP.users).doc(user.uid).snapshots().listen((snap) async {
      final data = snap.data() ?? <String, dynamic>{};
      final rolesLower = <String>{};
      String? memberId = data['memberId'] as String?;

      // users.roles array
      if (data['roles'] is List) {
        for (final v in List.from(data['roles'])) {
          if (v is String && v.trim().isNotEmpty) rolesLower.add(v.trim().toLowerCase());
        }
      }
      // users.role single
      if (data['role'] is String && (data['role'] as String).trim().isNotEmpty) {
        rolesLower.add((data['role'] as String).trim().toLowerCase());
      }
      // Boolean fallbacks
      if (data['isPastor'] == true) rolesLower.add('pastor');
      if (data['isAdmin'] == true) rolesLower.add('admin');

      // Custom claims
      try {
        final token = await user.getIdTokenResult(true);
        final claims = token.claims ?? {};
        if (claims['pastor'] == true || claims['isPastor'] == true) rolesLower.add('pastor');
        if (claims['admin'] == true || claims['isAdmin'] == true) rolesLower.add('admin');
      } catch (_) {}

      var granted = rolesLower.contains('pastor') || rolesLower.contains('admin');
      Map<String, dynamic> memberData = const {};

      // 🔁 Member fallback (exactly like RoleGate in main.dart)
      if (!granted && memberId != null && memberId.isNotEmpty) {
        try {
          final mem = await _db.collection(FP.members).doc(memberId).get();
          memberData = mem.data() ?? {};
          final mRoles = (memberData['roles'] as List<dynamic>? ?? const [])
              .map((e) => e.toString().toLowerCase())
              .toSet();
          final leads = List<String>.from(memberData['leadershipMinistries'] ?? const <String>[]);
          if (mRoles.contains('admin')) {
            rolesLower.add('admin');
          } else if (mRoles.contains('pastor') || (memberData['isPastor'] == true)) {
            rolesLower.add('pastor');
          } else if (mRoles.contains('leader') || leads.isNotEmpty) {
            rolesLower.add('leader');
          }
          granted = rolesLower.contains('pastor') || rolesLower.contains('admin');
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _canModerate = granted;
        _loadingRole = false;
        _debug = {
          'uid': user.uid,
          'userDocPath': snap.reference.path,
          'user.roles': data['roles'],
          'user.role': data['role'],
          'user.isPastor': data['isPastor'],
          'user.isAdmin': data['isAdmin'],
          'user.memberId': memberId,
          'member.roles': memberData is Map ? memberData['roles'] : null,
          'member.isPastor': memberData is Map ? memberData['isPastor'] : null,
          'member.leadershipMinistries': memberData is Map ? memberData['leadershipMinistries'] : null,
          'resolvedRolesLower': rolesLower.toList(),
          'granted': granted,
        };
      });
    });
  }

  Future<void> _enqueueAction({
    required String requestId,
    required String action, // 'approve' | 'decline'
    String? reason,
  }) async {
    if (!_canModerate || _uid == null) return;

    await _db.collection('ministry_approval_actions').add({
      'action': action,
      'requestId': requestId,
      'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
      'byUid': _uid,
      'createdAt': FieldValue.serverTimestamp(),
      'processed': false,
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(action == 'approve' ? 'Approval queued' : 'Decline queued')),
    );
  }

  Future<void> _confirmDecline(String requestId) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decline request'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Optional: add a reason for declining',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Decline')),
        ],
      ),
    );
    if (ok == true) {
      await _enqueueAction(requestId: requestId, action: 'decline', reason: controller.text);
    }
  }

  Future<String> _resolveRequesterName({
    required String requestedByUid,
    String? fallbackFullName,
    String? fallbackEmail,
  }) async {
    if (_nameCache.containsKey(requestedByUid)) return _nameCache[requestedByUid]!;
    if ((fallbackFullName ?? '').trim().isNotEmpty) {
      _nameCache[requestedByUid] = fallbackFullName!.trim();
      return _nameCache[requestedByUid]!;
    }
    try {
      final u = await _db.collection(FP.users).doc(requestedByUid).get();
      final udata = u.data() ?? {};
      final memberId = (udata['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        final m = await _db.collection(FP.members).doc(memberId).get();
        if (m.exists) {
          final md = m.data() as Map<String, dynamic>;
          final fn = (md['firstName'] ?? '').toString().trim();
          final ln = (md['lastName'] ?? '').toString().trim();
          final full = [fn, ln].where((s) => s.isNotEmpty).join(' ').trim();
          if (full.isNotEmpty) {
            _nameCache[requestedByUid] = full;
            return full;
          }
        }
      }
    } catch (_) {}
    final fb = (fallbackEmail ?? '').trim();
    if (fb.isNotEmpty) {
      _nameCache[requestedByUid] = fb;
      return fb;
    }
    _nameCache[requestedByUid] = requestedByUid;
    return requestedByUid;
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_canModerate) {
      final pretty = const JsonEncoder().convert(_debug);
      return Scaffold(
        appBar: AppBar(title: const Text('Ministry Approvals')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Access denied.\nOnly pastors and admins can manage ministry creation requests.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (kDebugMode) ...[
                    const Divider(),
                    Text('Debug info:', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(pretty),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    final query = _db
        .collection('ministry_creation_requests')
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true);

    return Scaffold(
      appBar: AppBar(title: const Text('Ministry Approvals')),
      body: StreamBuilder<QuerySnapshot>(
        stream: query.snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No pending requests.'));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data() as Map<String, dynamic>;
              final id = d.id;

              final ministryName = (data['name'] ?? data['ministryName'] ?? '').toString();
              final description = (data['description'] ?? '').toString();
              final requestedByUid = (data['requestedByUid'] ?? '').toString();
              final requesterEmail = (data['requesterEmail'] ?? '').toString();
              final requesterFullName = (data['requesterFullName'] ?? '').toString();
              final ts = data['requestedAt'];
              final requestedAt = ts is Timestamp ? ts.toDate() : null;

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ministryName.isEmpty ? 'Unnamed Ministry' : ministryName,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 6),
                      if (description.isNotEmpty) Text(description),
                      const SizedBox(height: 6),
                      FutureBuilder<String>(
                        future: _resolveRequesterName(
                          requestedByUid: requestedByUid,
                          fallbackFullName: requesterFullName.isNotEmpty ? requesterFullName : null,
                          fallbackEmail: requesterEmail.isNotEmpty ? requesterEmail : null,
                        ),
                        builder: (context, nameSnap) {
                          final name = nameSnap.data ?? '—';
                          return Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: [
                              _Chip('Requester', name),
                              if (requesterEmail.isNotEmpty) _Chip('Email', requesterEmail),
                              _Chip('Requested At', requestedAt?.toLocal().toString() ?? '—'),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: () => _confirmDecline(id),
                            icon: const Icon(Icons.cancel),
                            label: const Text('Decline'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: () => _enqueueAction(requestId: id, action: 'approve'),
                            icon: const Icon(Icons.check_circle),
                            label: const Text('Approve'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label: ${value.isEmpty ? '—' : value}'),
      visualDensity: VisualDensity.compact,
    );
  }
}
